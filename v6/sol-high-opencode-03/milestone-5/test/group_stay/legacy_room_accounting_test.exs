defmodule GroupStay.LegacyRoomAccountingTest do
  use GroupStay.DataCase

  alias GroupStay.Operations
  alias GroupStay.Operations.Record
  alias GroupStay.Payments.{CashAllocation, CashPayment}
  alias GroupStay.Reservations.{Group, Room}

  test "migration backfill preserves balances and allocates the senior legacy block first" do
    %Group{}
    |> Group.create_changeset(%{
      group_id: "legacy-group",
      guest_id: "guest",
      property_id: "property",
      booked_on: ~D[2026-10-01],
      arrival_on: ~D[2026-12-01],
      departure_on: ~D[2026-12-02],
      rate_plan: "flexible",
      policy_version: "flex-14",
      status: "active",
      lodging_total_cents: 20_000,
      deposit_due_cents: 4_000,
      deposit_paid_cents: 2_500,
      credit_paid_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      cash_converted_to_credit_cents: 0,
      accounting_initialized: false,
      revision: 2
    })
    |> Repo.insert!()

    for {room_id, position} <- [{"room-1", 0}, {"room-2", 1}] do
      Repo.insert!(%Room{
        group_id: "legacy-group",
        room_id: room_id,
        nightly_rate_cents: 10_000,
        position: position,
        status: "active",
        lodging_total_cents: 10_000,
        deposit_due_cents: 2_000
      })
    end

    submitted = %{
      "operation_id" => "durable-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => "legacy-group",
      "amount_cents" => 1_500
    }

    result = %{
      "operation_id" => "durable-pay",
      "status" => "applied",
      "group_id" => "legacy-group",
      "amount_cents" => 1_500,
      "outstanding_deposit_cents" => 1_500,
      "revision" => 2
    }

    %Record{}
    |> Record.changeset(%{
      operation_id: "durable-pay",
      operation_type: "record_cash_payment",
      submitted_content: submitted,
      result: result
    })
    |> Repo.insert!()

    assert :ok = Operations.backfill_room_accounting!()

    rooms = Repo.all(from room in Room, order_by: room.position)

    assert Repo.all(from allocation in CashAllocation, order_by: allocation.id)
           |> Enum.map(fn allocation ->
             {allocation.payment_operation_id,
              Enum.find(rooms, &(&1.id == allocation.room_id)).room_id, allocation.amount_cents}
           end) == [
             {nil, "room-1", 1_000},
             {"durable-pay", "room-1", 1_000},
             {"durable-pay", "room-2", 500}
           ]

    group = Repo.get!(Group, "legacy-group")
    assert group.accounting_initialized
    assert group.deposit_paid_cents == 2_500
    assert group.revision == 2

    assert {:ok, statement} = Operations.get_payment("durable-pay")

    assert statement == %{
             payment_operation_id: "durable-pay",
             original_group_id: "legacy-group",
             recorded_cents: 1_500,
             held_cents: 1_500,
             refunded_cents: 0,
             retained_cents: 0,
             converted_to_credit_cents: 0,
             reduced_cents: 0,
             charged_back_cents: 0
           }

    assert Repo.aggregate(CashPayment, :count) == 1
    assert Repo.aggregate(CashAllocation, :count) == 3
  end
end
