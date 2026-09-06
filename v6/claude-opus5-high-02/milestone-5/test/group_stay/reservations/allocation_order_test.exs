defmodule GroupStay.Reservations.AllocationOrderTest do
  @moduledoc """
  The upgrade that puts existing allocations into one shared order.

  This group is built the way a database written before room accounting holds it, and is then
  brought forward exactly as the upgrade brings it forward: room accounting lays the funding over
  the rooms, and deposit transfers number what it laid out. What comes out is the order the group
  was funded in, which is the order a transfer draws from and a correction unwinds.
  """

  use GroupStay.DataCase, async: false

  alias GroupStay.Partner.Record
  alias GroupStay.Reservations.AllocationOrder
  alias GroupStay.Reservations.Backfill
  alias GroupStay.Reservations.CashAllocation
  alias GroupStay.Reservations.CreditApplication
  alias GroupStay.Reservations.CreditLot
  alias GroupStay.Reservations.Funding
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Room

  describe "backfill/0" do
    setup do
      # 1_000 cash and 500 credit reach back before durable records existed; a payment and a credit
      # application recorded after them account for the rest.
      group =
        insert_group(
          group_id: "group-81",
          cash_paid_cents: 2_500,
          credit_paid_cents: 1_500,
          rooms: [{"room-a", 15_000, 3_000}, {"room-b", 15_000, 3_000}]
        )

      legacy_lot = insert_lot("cancel-01")
      recorded_lot = insert_lot("cancel-02")

      insert_application(group, legacy_lot, 500)

      remember("op-pay-1", "record_cash_payment", %{
        "group_id" => "group-81",
        "amount_cents" => 1_500
      })

      remember("op-credit-1", "apply_hotel_credit", %{
        "group_id" => "group-81",
        "amount_cents" => 1_000
      })

      insert_application(group, recorded_lot, 1_000)

      %{group: group, legacy_lot: legacy_lot, recorded_lot: recorded_lot}
    end

    test "numbers the unattributed block first and the recorded funding in commit order",
         context do
      %{group: group, legacy_lot: legacy_lot, recorded_lot: recorded_lot} = context

      Backfill.run()
      AllocationOrder.backfill()

      assert allocation_order(group) == [
               {1, :cash, nil, "room-a", 1_000},
               {2, :credit, legacy_lot.id, "room-a", 500},
               {3, :cash, "op-pay-1", "room-a", 1_500},
               {4, :credit, recorded_lot.id, "room-b", 1_000}
             ]
    end

    test "leaves the sequence where new funding can carry on from it", %{group: group} do
      Backfill.run()
      AllocationOrder.backfill()

      assert Funding.next_seq() == 5

      # Nothing about what the group holds changed, only the order it is known to have been
      # funded in.
      group = Repo.get!(Group, group.id)
      assert group.cash_paid_cents == 2_500
      assert group.credit_paid_cents == 1_500
    end
  end

  ## A database as an earlier release left it

  defp insert_group(attrs) do
    rooms = Keyword.fetch!(attrs, :rooms)

    Repo.insert!(%Group{
      group_id: Keyword.fetch!(attrs, :group_id),
      guest_id: "guest-22",
      property_id: "ams-canal",
      booked_on: ~D[2026-10-03],
      arrival_on: ~D[2026-12-10],
      departure_on: ~D[2026-12-11],
      rate_plan: "flexible",
      policy_version: "flex-14",
      status: "active",
      revision: 1,
      lodging_total_cents: Enum.sum(Enum.map(rooms, fn {_id, rate, _deposit} -> rate end)),
      deposit_due_cents: Enum.sum(Enum.map(rooms, fn {_id, _rate, deposit} -> deposit end)),
      cash_paid_cents: Keyword.fetch!(attrs, :cash_paid_cents),
      credit_paid_cents: Keyword.fetch!(attrs, :credit_paid_cents),
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

  defp insert_lot(source_operation_id) do
    Repo.insert!(%CreditLot{
      guest_id: "guest-22",
      source_operation_id: source_operation_id,
      issued_on: ~D[2026-09-01],
      expires_on: ~D[2027-09-01],
      original_cents: 1_500,
      remaining_cents: 0
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

  ## Reading the order back

  defp allocation_order(group) do
    cash =
      Repo.all(
        from a in CashAllocation,
          join: r in Room,
          on: r.id == a.room_id,
          where: a.group_id == ^group.id,
          select: {a.allocation_seq, :cash, a.payment_operation_id, r.room_id, a.amount_cents}
      )

    credit =
      Repo.all(
        from a in CreditApplication,
          join: r in Room,
          on: r.id == a.room_id,
          where: a.group_id == ^group.id,
          select: {a.allocation_seq, :credit, a.credit_lot_id, r.room_id, a.amount_cents}
      )

    Enum.sort(cash ++ credit)
  end
end
