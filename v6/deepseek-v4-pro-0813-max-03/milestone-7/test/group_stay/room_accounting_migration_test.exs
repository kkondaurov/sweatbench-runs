defmodule GroupStay.RoomAccountingMigrationTest do
  use GroupStay.DataCase, async: false

  alias GroupStay.Accounting
  alias GroupStay.Accounting.PaymentDisposition
  alias GroupStay.Accounting.RoomAllocation
  alias GroupStay.Credit.CreditAllocation
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  defp insert_legacy_group(overrides) do
    base = %{
      group_id: "legacy-g",
      guest_id: "guest-leg",
      property_id: "prop-1",
      status: "active",
      rate_plan: "flexible",
      booked_on: ~D[2026-10-03],
      arrival_on: ~D[2026-12-10],
      departure_on: ~D[2026-12-13],
      revision: 1,
      lodging_total_cents: 60_000,
      deposit_due_cents: 12_000,
      deposit_paid_cents: 5_000,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0
    }

    group = Repo.insert!(struct!(Group, Map.merge(base, overrides)))

    for {room_id, rate, position} <- [{"r1", 10_000, 0}, {"r2", 10_000, 1}] do
      Repo.insert!(%Room{
        group_id: group.id,
        room_id: room_id,
        nightly_rate_cents: rate,
        position: position,
        status: "active",
        lodging_cents: 0,
        deposit_due_cents: 0
      })
    end

    group
  end

  describe "bringing legacy funding forward" do
    test "backfills room amounts and allocates the senior block without changing balances" do
      group = insert_legacy_group(%{credit_paid_cents: 2_000})

      lot =
        Repo.insert!(%CreditLot{
          guest_id: "guest-leg",
          source_operation_id: "legacy-cancel",
          remaining_cents: 3_000,
          expires_on: ~D[2027-11-26]
        })

      Repo.insert!(%CreditAllocation{group_id: group.id, lot_id: lot.id, amount_cents: 2_000})

      Accounting.backfill_rooms!()

      rooms = Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: r.position)
      assert Enum.map(rooms, & &1.lodging_cents) == [30_000, 30_000]
      assert Enum.map(rooms, & &1.deposit_due_cents) == [6_000, 6_000]
      assert Enum.map(rooms, & &1.status) == ["active", "active"]

      Accounting.reconcile_all!()

      rows = Repo.all(from a in RoomAllocation, order_by: a.id)

      [room1, room2] = rooms

      assert Enum.map(
               rows,
               &Map.take(&1, [
                 :group_id,
                 :room_id,
                 :kind,
                 :source_operation_id,
                 :lot_id,
                 :amount_cents
               ])
             ) ==
               [
                 %{
                   group_id: group.id,
                   room_id: room1.id,
                   kind: "cash",
                   source_operation_id: nil,
                   lot_id: nil,
                   amount_cents: 5_000
                 },
                 %{
                   group_id: group.id,
                   room_id: room1.id,
                   kind: "credit",
                   source_operation_id: nil,
                   lot_id: lot.id,
                   amount_cents: 1_000
                 },
                 %{
                   group_id: group.id,
                   room_id: room2.id,
                   kind: "credit",
                   source_operation_id: nil,
                   lot_id: lot.id,
                   amount_cents: 1_000
                 }
               ]

      # Aggregate balances are unchanged by creating room allocations.
      assert Repo.get!(Group, group.id).deposit_paid_cents == 5_000
      assert Repo.get!(Group, group.id).credit_paid_cents == 2_000
      assert Repo.get!(CreditLot, lot.id).remaining_cents == 3_000
      assert Repo.aggregate(CreditAllocation, :count, :id) == 0

      # Re-running reconciliation is a no-op.
      Accounting.reconcile_all!()
      assert Repo.aggregate(RoomAllocation, :count, :id) == 3
    end

    test "records settled dispositions for a fully settled legacy group" do
      insert_legacy_group(%{
        status: "cancelled",
        deposit_paid_cents: 4_000,
        refunded_cents: 4_000
      })

      Accounting.reconcile_all!()

      assert [%{payment_operation_id: nil, kind: "refunded", amount_cents: 4_000}] =
               Repo.all(PaymentDisposition)

      assert Repo.aggregate(RoomAllocation, :count, :id) == 0
    end
  end
end
