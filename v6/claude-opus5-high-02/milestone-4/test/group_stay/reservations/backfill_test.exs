defmodule GroupStay.Reservations.BackfillTest do
  @moduledoc """
  The upgrade that gives existing funding a room.

  These groups are built the way a database written by an earlier release holds them: aggregate
  cash and credit on the group, credit applications with no room, and no allocations at all. Some
  of that funding was submitted before operations were durably recorded and can never be named
  again; the rest is recognisable from the records the gateway's submissions left behind.
  """

  use GroupStay.DataCase, async: false

  import GroupStay.OperationFixtures

  alias GroupStay.Partner
  alias GroupStay.Partner.Record
  alias GroupStay.Reservations
  alias GroupStay.Reservations.Backfill
  alias GroupStay.Reservations.CashAllocation
  alias GroupStay.Reservations.CreditApplication
  alias GroupStay.Reservations.CreditLot
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Room

  describe "run/1" do
    setup do
      group =
        insert_group(
          group_id: "group-81",
          cash_paid_cents: 4_300,
          credit_paid_cents: 1_500,
          rooms: [{"room-a", 10_000, 2_000}, {"room-b", 20_000, 4_000}]
        )

      first_lot = insert_lot("cancel-01", 0)
      second_lot = insert_lot("cancel-02", 0)

      # 1_800 cash and 500 credit reach back before durable records existed.
      legacy = insert_application(group, first_lot, 500)

      remember("op-pay-1", "record_cash_payment", %{
        "group_id" => "group-81",
        "amount_cents" => 1_500
      })

      remember("op-credit-1", "apply_hotel_credit", %{
        "group_id" => "group-81",
        "amount_cents" => 1_000
      })

      recorded = insert_application(group, second_lot, 1_000)

      remember("op-pay-2", "record_cash_payment", %{
        "group_id" => "group-81",
        "amount_cents" => 1_000
      })

      %{group: group, legacy: legacy, recorded: recorded, first_lot: first_lot}
    end

    test "lays the unattributed block over the rooms before the recorded funding", %{group: group} do
      Backfill.run()

      assert allocations(group) == [
               {nil, "room-a", 1_800, "held"},
               {"op-pay-1", "room-b", 1_500, "held"},
               {"op-pay-2", "room-b", 1_000, "held"}
             ]
    end

    test "splits credit that fills more than one room, keeping its lot", context do
      %{group: group, legacy: legacy, recorded: recorded, first_lot: first_lot} = context

      Backfill.run()

      # A row per lot and room; a split leaves the credit and the lot it came from untouched.
      assert Enum.sort(applications(group)) == [
               {first_lot.id, "room-a", 200, "applied"},
               {first_lot.id, "room-b", 300, "applied"},
               {recorded.credit_lot_id, "room-b", 1_000, "applied"}
             ]

      assert Repo.get!(CreditApplication, legacy.id).amount_cents == 200
    end

    test "changes where the balances sit and not what they are", %{group: group} do
      liability_before = Reservations.ledger_totals(~D[2026-10-10]).credit_liability_cents

      Backfill.run()

      group = Repo.get!(Group, group.id)
      assert group.cash_paid_cents == 4_300
      assert group.credit_paid_cents == 1_500
      assert group.deposit_due_cents == 6_000
      assert group.lodging_total_cents == 30_000

      totals = Reservations.ledger_totals(~D[2026-10-10])
      assert totals.cash_held_cents == 4_300
      assert totals.credit_liability_cents == liability_before

      assert [
               %{room_id: "room-a", cash_paid_cents: 1_800, credit_paid_cents: 200},
               %{room_id: "room-b", cash_paid_cents: 2_500, credit_paid_cents: 1_300}
             ] = rooms(group)
    end

    test "leaves the funding it brought forward correctable and the rest not" do
      Backfill.run()

      assert submit_one(
               reduce_cash_payment(%{"payment_operation_id" => "op-pay-2", "amount_cents" => 400})
             )["outstanding_deposit_cents"] == 600

      # The unattributed block has no operation identity, so nothing can name it.
      assert submit_one(
               reduce_cash_payment(%{
                 "operation_id" => "op-reduce-legacy",
                 "payment_operation_id" => "op-open-81",
                 "amount_cents" => 100
               })
             )["code"] == "operation_not_found"

      assert Reservations.ledger_totals(~D[2026-10-10]).cash_held_cents == 3_900
    end

    test "classifies the cash of a group that was already settled" do
      settled =
        insert_group(
          group_id: "group-2",
          status: "cancelled",
          cash_paid_cents: 1_000,
          rooms: [{"room-a", 10_000, 2_000}]
        )

      Backfill.run(%{settled.id => "refunded"})

      assert allocations(settled) == [{nil, "room-a", 1_000, "refunded"}]
      assert [%{status: "cancelled", cash_paid_cents: 0}] = rooms(settled)

      settled = Repo.get!(Group, settled.id)
      assert settled.deposit_due_cents == 0
      assert settled.cash_paid_cents == 0

      totals = Reservations.ledger_totals(~D[2026-10-10])
      assert totals.cash_refunded_cents == 1_000
      assert totals.cash_held_cents == 4_300
    end

    test "links cash that a recorded cancellation had converted into a lot" do
      converted =
        insert_group(
          group_id: "group-3",
          guest_id: "guest-33",
          status: "cancelled",
          cash_paid_cents: 1_000,
          rooms: [{"room-a", 10_000, 2_000}]
        )

      lot = insert_lot("op-cancel-3", 1_100, guest_id: "guest-33")

      remember("op-pay-3", "record_cash_payment", %{
        "group_id" => "group-3",
        "amount_cents" => 1_000
      })

      remember("op-cancel-3", "cancel_group", %{
        "group_id" => "group-3",
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "credit_issued_cents" => 1_100
      })

      Backfill.run(%{converted.id => "converted"})

      assert allocations(converted) == [{"op-pay-3", "room-a", 1_000, "converted"}]

      # The lot the cash bought can now be taken back from the guest with it.
      assert submit_one(charge_back_payment(%{"payment_operation_id" => "op-pay-3"}))[
               "charged_back_cents"
             ] == 1_000

      assert Repo.get!(CreditLot, lot.id).remaining_cents == 0

      totals = Reservations.ledger_totals(~D[2026-10-10])
      assert totals.cash_converted_to_credit_cents == 0
      assert totals.cash_charged_back_cents == 1_000
    end
  end

  ## A database as an earlier release left it

  defp insert_group(attrs) do
    rooms = Keyword.fetch!(attrs, :rooms)

    Repo.insert!(%Group{
      group_id: Keyword.fetch!(attrs, :group_id),
      guest_id: Keyword.get(attrs, :guest_id, "guest-22"),
      property_id: "ams-canal",
      booked_on: ~D[2026-10-03],
      arrival_on: ~D[2026-12-10],
      departure_on: ~D[2026-12-11],
      rate_plan: "flexible",
      policy_version: "flex-14",
      status: Keyword.get(attrs, :status, "active"),
      revision: 1,
      lodging_total_cents: Enum.sum(Enum.map(rooms, fn {_id, rate, _deposit} -> rate end)),
      deposit_due_cents: Enum.sum(Enum.map(rooms, fn {_id, _rate, deposit} -> deposit end)),
      cash_paid_cents: Keyword.get(attrs, :cash_paid_cents, 0),
      credit_paid_cents: Keyword.get(attrs, :credit_paid_cents, 0),
      rooms:
        for {{room_id, rate, deposit}, position} <- Enum.with_index(rooms) do
          %Room{
            room_id: room_id,
            nightly_rate_cents: rate,
            lodging_cents: rate,
            deposit_cents: deposit,
            position: position
          }
        end
    })
  end

  defp insert_lot(source_operation_id, remaining_cents, opts \\ []) do
    Repo.insert!(%CreditLot{
      guest_id: Keyword.get(opts, :guest_id, "guest-22"),
      source_operation_id: source_operation_id,
      issued_on: ~D[2026-09-01],
      expires_on: ~D[2027-09-01],
      original_cents: max(remaining_cents, 1_000),
      remaining_cents: remaining_cents
    })
  end

  defp insert_application(group, lot, amount_cents) do
    Repo.insert!(%CreditApplication{
      group_id: group.id,
      credit_lot_id: lot.id,
      amount_cents: amount_cents,
      applied_on: ~D[2026-10-04],
      status: "applied"
    })
  end

  defp remember(operation_id, type, result) do
    Repo.insert!(%Record{
      operation_id: operation_id,
      type: type,
      payload: ~s({"operation_id":"#{operation_id}"}),
      result:
        Jason.encode!(Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, result))
    })
  end

  ## Reading what the backfill produced

  defp allocations(group) do
    Repo.all(
      from a in CashAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        where: a.group_id == ^group.id,
        order_by: [asc: a.id],
        select: {a.payment_operation_id, r.room_id, a.amount_cents, a.status}
    )
  end

  defp applications(group) do
    Repo.all(
      from a in CreditApplication,
        join: r in Room,
        on: r.id == a.room_id,
        where: a.group_id == ^group.id,
        order_by: [asc: a.id],
        select: {a.credit_lot_id, r.room_id, a.amount_cents, a.status}
    )
  end

  defp rooms(group) do
    Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: [asc: r.position])
  end

  defp submit_one(operation) do
    [result] = Partner.process([operation])
    result
  end
end
