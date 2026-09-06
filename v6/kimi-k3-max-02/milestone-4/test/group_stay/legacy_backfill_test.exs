defmodule GroupStay.LegacyBackfillTest do
  @moduledoc """
  Covers `GroupStay.Groups.bring_forward_legacy_funding/0`, the data half of
  the room-accounting migration: funding recorded before durable operation
  records existed comes forward as one unattributed senior block per group,
  ahead of the funding described by durable records, without changing any
  aggregate cash, credit, or liability balance.
  """
  use GroupStay.DataCase

  alias GroupStay.Groups

  alias GroupStay.Groups.{
    CashFunding,
    CreditApplication,
    CreditLot,
    CreditLotEntitlement,
    Group,
    RoomFunding
  }

  defp insert_group!(attrs) do
    rooms = Keyword.fetch!(attrs, :rooms)

    defaults = [
      guest_id: "guest-22",
      property_id: "ams-canal",
      booked_on: ~D[2026-10-03],
      arrival_on: ~D[2026-12-10],
      departure_on: ~D[2026-12-13],
      rate_plan: "flexible",
      policy_version: "flex-14",
      status: "active",
      revision: 1,
      lodging_total_cents: Enum.sum(for room <- rooms, do: room[:lodging_total_cents]),
      deposit_due_cents: Enum.sum(for room <- rooms, do: room[:deposit_due_cents]),
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      cash_converted_cents: 0
    ]

    room_attrs =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          room_id: room[:room_id],
          nightly_rate_cents: room[:nightly_rate_cents],
          position: position,
          lodging_total_cents: room[:lodging_total_cents],
          deposit_due_cents: room[:deposit_due_cents]
        }
      end)

    attrs = defaults |> Keyword.merge(attrs) |> Map.new() |> Map.put(:rooms, room_attrs)

    %Group{} |> Group.changeset(attrs) |> Repo.insert!()
  end

  defp insert_record!(operation_id, type, submission, result) do
    %Groups.OperationRecord{}
    |> Groups.OperationRecord.changeset(%{
      operation_id: operation_id,
      type: type,
      submission: submission,
      result: result
    })
    |> Repo.insert!()
  end

  defp fundings(group) do
    Repo.all(from f in CashFunding, where: f.group_id == ^group.id, order_by: [asc: f.id])
  end

  defp room_allocations(group, room_id) do
    room =
      Repo.one!(from r in Groups.Room, where: r.group_id == ^group.id and r.room_id == ^room_id)

    Repo.all(
      from rf in RoomFunding,
        where: rf.room_id == ^room.id and rf.status == "held",
        order_by: [asc: rf.inserted_at],
        select: {rf.kind, rf.amount_cents}
    )
  end

  test "an active group's legacy funding becomes the senior block ahead of durable records" do
    group =
      insert_group!(
        group_id: "group-a",
        cash_paid_cents: 10000,
        credit_paid_cents: 3000,
        deposit_paid_cents: 13000,
        rooms: [
          %{
            room_id: "room-a",
            nightly_rate_cents: 15000,
            lodging_total_cents: 45000,
            deposit_due_cents: 9000
          },
          %{
            room_id: "room-b",
            nightly_rate_cents: 17500,
            lodging_total_cents: 52500,
            deposit_due_cents: 10500
          }
        ]
      )

    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: "guest-22",
        source_operation_id: "op-old-cancel",
        original_cents: 20000,
        remaining_cents: 17000,
        expires_on: ~D[2027-11-26]
      })
      |> Repo.insert!()

    %CreditApplication{}
    |> CreditApplication.changeset(%{
      credit_lot_id: lot.id,
      group_id: group.id,
      amount_cents: 3000,
      status: "applied"
    })
    |> Repo.insert!()

    insert_record!(
      "op-p1",
      "record_cash_payment",
      %{
        "operation_id" => "op-p1",
        "type" => "record_cash_payment",
        "group_id" => "group-a",
        "amount_cents" => 4000
      },
      %{
        "operation_id" => "op-p1",
        "status" => "applied",
        "group_id" => "group-a",
        "amount_cents" => 4000,
        "outstanding_deposit_cents" => 15500,
        "revision" => 2
      }
    )

    Groups.bring_forward_legacy_funding()

    # the unattributed senior block holds the unrecorded 6000 of cash and
    # comes ahead of the durable payment
    assert [
             %CashFunding{operation_id: nil, amount_cents: 6000, held_cents: 6000},
             %CashFunding{operation_id: "op-p1", amount_cents: 4000, held_cents: 4000}
           ] = fundings(group)

    # legacy cash first, then the legacy credit lot, then durable funding
    assert room_allocations(group, "room-a") == [{"cash", 6000}, {"credit", 3000}]
    assert room_allocations(group, "room-b") == [{"cash", 4000}]

    # no aggregate balance changed
    {:ok, presented} = Groups.get_group("group-a")
    assert presented.deposit_paid_cents == 13000
    assert presented.cash_paid_cents == 10000
    assert presented.credit_paid_cents == 3000
    assert presented.deposit_due_cents - presented.deposit_paid_cents == 6500
  end

  test "a refunded legacy cancellation settles its senior block as refunded" do
    group =
      insert_group!(
        group_id: "group-b",
        status: "cancelled",
        cash_paid_cents: 5000,
        deposit_paid_cents: 5000,
        refunded_cents: 5000,
        rooms: [
          %{
            room_id: "room-a",
            nightly_rate_cents: 15000,
            lodging_total_cents: 45000,
            deposit_due_cents: 9000
          }
        ]
      )

    Groups.bring_forward_legacy_funding()

    assert [%CashFunding{operation_id: nil, held_cents: 0, refunded_cents: 5000}] =
             fundings(group)

    assert Repo.one!(
             from r in Groups.Room,
               where: r.group_id == ^group.id,
               select: {r.status, r.refunded_cents}
           ) ==
             {"cancelled", 5000}

    # a cancelled group has no active rooms, so its totals are zero
    {:ok, presented} = Groups.get_group("group-b")
    assert presented.deposit_due_cents == 0
    assert presented.deposit_paid_cents == 0
  end

  test "a converted cancellation records the durable payment's lot entitlement" do
    group =
      insert_group!(
        group_id: "group-c",
        status: "cancelled",
        cash_paid_cents: 5000,
        deposit_paid_cents: 5000,
        cash_converted_cents: 5000,
        rooms: [
          %{
            room_id: "room-a",
            nightly_rate_cents: 15000,
            lodging_total_cents: 45000,
            deposit_due_cents: 9000
          }
        ]
      )

    insert_record!(
      "op-p3",
      "record_cash_payment",
      %{"operation_id" => "op-p3", "type" => "record_cash_payment", "group_id" => "group-c"},
      %{
        "operation_id" => "op-p3",
        "status" => "applied",
        "group_id" => "group-c",
        "amount_cents" => 5000,
        "revision" => 2
      }
    )

    insert_record!(
      "op-c3",
      "cancel_group",
      %{
        "operation_id" => "op-c3",
        "type" => "cancel_group",
        "group_id" => "group-c",
        "refund_method" => "hotel_credit"
      },
      %{
        "operation_id" => "op-c3",
        "status" => "applied",
        "group_id" => "group-c",
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "credit_issued_cents" => 5500,
        "revision" => 3
      }
    )

    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: "guest-22",
        source_operation_id: "op-c3",
        original_cents: 5500,
        remaining_cents: 5500,
        expires_on: ~D[2027-11-26]
      })
      |> Repo.insert!()

    Groups.bring_forward_legacy_funding()

    assert [%CashFunding{operation_id: "op-p3", held_cents: 0, converted_cents: 5000}] =
             fundings(group)

    assert [
             %CreditLotEntitlement{
               credit_lot_id: lot_id,
               entitlement_cents: 5500,
               revoked_cents: 0
             }
           ] = Repo.all(CreditLotEntitlement)

    assert lot_id == lot.id

    # the durable payment can be reconciled and charged back afterwards
    assert {:ok, statement} = Groups.get_payment_statement("op-p3")
    assert statement.converted_to_credit_cents == 5000
  end

  test "a retained legacy cancellation settles its senior block as retained" do
    group =
      insert_group!(
        group_id: "group-d",
        status: "cancelled",
        cash_paid_cents: 7000,
        deposit_paid_cents: 7000,
        retained_cents: 7000,
        rooms: [
          %{
            room_id: "room-a",
            nightly_rate_cents: 15000,
            lodging_total_cents: 45000,
            deposit_due_cents: 9000
          }
        ]
      )

    Groups.bring_forward_legacy_funding()

    assert [%CashFunding{operation_id: nil, held_cents: 0, retained_cents: 7000}] =
             fundings(group)

    assert Groups.ledger_totals(~D[2027-01-01]).cash_retained_cents == 7000
  end

  test "groups without funding gain no allocations" do
    group =
      insert_group!(
        group_id: "group-e",
        rooms: [
          %{
            room_id: "room-a",
            nightly_rate_cents: 15000,
            lodging_total_cents: 45000,
            deposit_due_cents: 9000
          }
        ]
      )

    Groups.bring_forward_legacy_funding()

    assert fundings(group) == []
    assert room_allocations(group, "room-a") == []

    {:ok, presented} = Groups.get_group("group-e")
    assert presented.deposit_due_cents == 9000
    assert presented.deposit_due_cents - presented.deposit_paid_cents == 9000
  end
end
