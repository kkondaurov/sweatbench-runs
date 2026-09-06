defmodule GroupStay.Deposits.LegacyBackfillTest do
  use GroupStay.DataCase

  import Ecto.Query

  alias GroupStay.Deposits.CashAllocation
  alias GroupStay.Deposits.CreditApplication
  alias GroupStay.Deposits.CreditLot
  alias GroupStay.Deposits.Group
  alias GroupStay.Deposits.LegacyBackfill
  alias GroupStay.Deposits.LedgerEntry
  alias GroupStay.Deposits.Room
  alias GroupStay.Repo
  alias GroupStay.Operations.Record

  # Rooms r1 and r2 of every seeded group: lodgings 45_000 and 52_500,
  # deposits 9_000 and 10_500 under the flexible plan.
  defp insert_group(group_id, status) do
    Repo.insert!(%Group{
      group_id: group_id,
      guest_id: "guest-22",
      property_id: "ams-canal",
      booked_on: ~D[2026-09-01],
      arrival_on: ~D[2026-12-10],
      departure_on: ~D[2026-12-13],
      rate_plan: "flexible",
      status: status,
      revision: 5,
      lodging_total_cents: 97_500,
      deposit_due_cents: 19_500,
      policy_version: "flex-14"
    })
  end

  defp insert_rooms(group) do
    [
      Repo.insert!(%Room{
        group_id: group.id,
        position: 0,
        room_id: "room-a",
        nightly_rate_cents: 15_000,
        lodging_amount_cents: 45_000,
        deposit_due_cents: 9_000,
        status: "active"
      }),
      Repo.insert!(%Room{
        group_id: group.id,
        position: 1,
        room_id: "room-b",
        nightly_rate_cents: 17_500,
        lodging_amount_cents: 52_500,
        deposit_due_cents: 10_500,
        status: "active"
      })
    ]
  end

  defp insert_entry(attrs, at) do
    {_count, _} =
      Repo.insert_all(LedgerEntry, [
        Map.merge(
          %{occurred_on: ~D[2026-09-30], operation_id: nil},
          Map.merge(attrs, %{inserted_at: at, updated_at: at})
        )
      ])
  end

  defp insert_lot(source_operation_id, issued, remaining) do
    Repo.insert!(%CreditLot{
      guest_id: "guest-22",
      source_operation_id: source_operation_id,
      issued_cents: issued,
      remaining_cents: remaining,
      expires_on: ~D[2027-11-27]
    })
  end

  defp insert_application(group, lot, amount, at) do
    {_count, _} =
      Repo.insert_all(CreditApplication, [
        %{
          group_id: group.id,
          credit_lot_id: lot.id,
          amount_cents: amount,
          inserted_at: at,
          updated_at: at
        }
      ])
  end

  defp insert_record(operation_id, type, payload, result, at) do
    {_count, _} =
      Repo.insert_all(Record, [
        %{
          operation_id: operation_id,
          type: type,
          payload: Jason.encode!(payload),
          result: Jason.encode!(result),
          inserted_at: at,
          updated_at: at
        }
      ])
  end

  defp cash_entries_total do
    LedgerEntry |> where(kind: "cash") |> Repo.aggregate(:sum, :amount_cents) || 0
  end

  test "allocates the unattributed senior block first, then durable records in commit order" do
    g1 = insert_group("group-g1", "active")
    [room_a, room_b] = insert_rooms(g1)

    durable_at = ~U[2026-10-04T12:00:00Z]
    legacy_after_durable = ~U[2026-10-06T09:00:00Z]

    # Durable payment and its matching ledger entry commit together.
    insert_record(
      "pay-dur",
      "record_cash_payment",
      %{
        "operation_id" => "pay-dur",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-g1",
        "amount_cents" => 3_000
      },
      %{
        "operation_id" => "pay-dur",
        "status" => "applied",
        "group_id" => "group-g1",
        "amount_cents" => 3_000,
        "outstanding_deposit_cents" => 16_500,
        "revision" => 2
      },
      durable_at
    )

    insert_entry(%{group_id: g1.id, kind: "cash", amount_cents: 3_000}, durable_at)

    # Durable hotel-credit application and its lot.
    lot_two = insert_lot("apply-dur-source", 2_000, 500)

    insert_record(
      "apply-dur",
      "apply_hotel_credit",
      %{
        "operation_id" => "apply-dur",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-g1",
        "amount_cents" => 1_500
      },
      %{
        "operation_id" => "apply-dur",
        "status" => "applied",
        "group_id" => "group-g1",
        "amount_cents" => 1_500,
        "outstanding_deposit_cents" => 15_000,
        "revision" => 3
      },
      durable_at
    )

    insert_application(g1, lot_two, 1_500, durable_at)

    # Legacy funding carries no operation record; its timestamps are newer than
    # the durable ones because seniority comes from attribution, not from time.
    insert_entry(%{group_id: g1.id, kind: "cash", amount_cents: 4_000}, legacy_after_durable)

    lot_one = insert_lot("legacy-cancel", 2_200, 200)
    insert_application(g1, lot_one, 2_000, legacy_after_durable)

    totals_before = %{
      cash: cash_entries_total(),
      lots: Enum.map(Repo.all(CreditLot), &{&1.id, &1.remaining_cents})
    }

    LegacyBackfill.run()

    allocations =
      Repo.all(from(a in CashAllocation, order_by: a.fill_seq))
      |> Repo.preload(:room)

    assert [
             %{operation_id: nil, amount_cents: 4_000, fill_seq: 1},
             %{operation_id: "pay-dur", amount_cents: 3_000, fill_seq: 3}
           ] = allocations

    assert Enum.map(allocations, & &1.room.room_id) == ["room-a", "room-a"]
    assert allocations |> hd() |> then(& &1.room.id) == room_a.id
    refute hd(allocations).room.id == room_b.id

    applications =
      Repo.all(from(a in CreditApplication, order_by: a.fill_seq)) |> Repo.preload(:room)

    assert [
             %{amount_cents: 2_000, fill_seq: 2},
             %{amount_cents: 1_500, fill_seq: 4}
           ] = applications

    assert Enum.map(applications, & &1.room.room_id) == ["room-a", "room-b"]

    # Creating allocations changed no aggregate balance.
    assert cash_entries_total() == totals_before.cash

    assert Enum.map(Repo.all(CreditLot), &{&1.id, &1.remaining_cents}) == totals_before.lots
  end

  test "skips groups that are already cancelled" do
    cancelled = insert_group("group-cancelled", "cancelled")
    insert_rooms(cancelled)

    insert_entry(
      %{group_id: cancelled.id, kind: "cash", amount_cents: 8_000},
      ~U[2026-09-20T08:00:00Z]
    )

    LegacyBackfill.run()

    assert Repo.all(CashAllocation) == []
    assert Repo.all(from(a in CreditApplication, select: a.fill_seq)) == []
  end

  test "leaves an unfunded active group without allocations" do
    group = insert_group("group-empty", "active")
    insert_rooms(group)

    LegacyBackfill.run()

    assert Repo.all(CashAllocation) == []
  end
end
