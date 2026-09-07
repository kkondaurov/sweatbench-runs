defmodule GroupStay.RoomAccountingBackfillTest do
  use GroupStay.DataCase

  alias GroupStay.PartnerOperations.OperationRecord
  alias GroupStay.Payments
  alias GroupStay.Repo
  alias GroupStay.Reservations
  alias GroupStay.Reservations.{Group, Room}
  alias GroupStay.RoomAccountingBackfill

  test "allocates unattributed cash ahead of durable funding without changing totals" do
    group =
      %Group{}
      |> Group.open_changeset(%{
        group_id: "legacy-group",
        guest_id: "guest",
        property_id: "hotel",
        booked_on: ~D[2026-09-01],
        arrival_on: ~D[2026-12-01],
        departure_on: ~D[2026-12-02],
        rate_plan: "flexible",
        policy_version: "flex-14",
        status: "active",
        revision: 2,
        lodging_total_cents: 20_000,
        deposit_due_cents: 4_000,
        deposit_paid_cents: 3_000,
        cash_paid_cents: 3_000,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0
      })
      |> Repo.insert!()

    insert_room(group, "first", 0)
    insert_room(group, "second", 1)

    %OperationRecord{}
    |> OperationRecord.changeset(%{
      operation_id: "durable-payment",
      operation_type: "record_cash_payment",
      submission: %{
        "operation_id" => "durable-payment",
        "type" => "record_cash_payment",
        "group_id" => group.group_id,
        "amount_cents" => 1_000
      },
      result: %{
        "operation_id" => "durable-payment",
        "status" => "applied",
        "group_id" => group.group_id,
        "amount_cents" => 1_000,
        "outstanding_deposit_cents" => 1_000,
        "revision" => 2
      }
    })
    |> Repo.insert!()

    RoomAccountingBackfill.run(Repo)

    assert {:ok, reservation} = Reservations.fetch_group(group.group_id)
    assert Enum.map(reservation.rooms, & &1.cash_paid_cents) == [2_000, 1_000]
    assert reservation.cash_paid_cents == 3_000
    assert reservation.deposit_paid_cents == 3_000

    assert {:ok, statement} = Payments.fetch_statement("durable-payment")
    assert statement.recorded_cents == 1_000
    assert statement.held_cents == 1_000
    assert Reservations.ledger_totals(~D[2026-09-01]).cash_held_cents == 3_000
  end

  defp insert_room(group, room_id, position) do
    %Room{}
    |> Room.changeset(%{
      group_record_id: group.id,
      room_id: room_id,
      nightly_rate_cents: 10_000,
      position: position,
      status: "active",
      lodging_total_cents: 0,
      deposit_due_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0
    })
    |> Repo.insert!()
  end
end
