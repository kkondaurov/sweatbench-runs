defmodule GroupStay.MigrationTest do
  use ExUnit.Case, async: false

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "original databases upgrade with booking policies and cash accounting intact" do
    path = Path.expand("tmp/upgrade-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_000, log: false)

    for {id, booked, plan, status} <- [
          {"old", "2026-12-31", "flexible", "active"},
          {"new", "2027-01-01", "flexible", "active"},
          {"advance", "2026-12-31", "advance_purchase", "cancelled"}
        ] do
      Ecto.Adapters.SQL.query!(
        UpgradeRepo,
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, refunded_cents, retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2028-06-01', '2028-06-02', ?, ?, 7, '[]', 1000, 200, 100, 0, 0)
        """,
        [id, booked, plan, status]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
    previous = GroupStay.Repo.put_dynamic_repo(UpgradeRepo)

    try do
      for {id, policy, cutoff} <- [
            {"old", "flex-14", ~D[2028-05-18]},
            {"new", "flex-30", ~D[2028-05-02]},
            {"advance", "advance-nonrefundable", nil}
          ] do
        group = GroupStay.Reservations.get_group(id)
        assert group.policy_version == policy
        assert group.refundable_until == cutoff
        assert group.cash_paid_cents == 100
        assert group.credit_paid_cents == 0
        assert group.deposit_paid_cents == 100
        assert group.revision == 7
      end

      assert GroupStay.Reservations.ledger().cash_held_cents == 200
      assert GroupStay.Reservations.ledger().credit_liability_cents == 0
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end

  test "durable operations migration preserves existing credit funding without reconstructing records" do
    path = Path.expand("tmp/credit-upgrade-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_001, log: false)
    previous = GroupStay.Repo.put_dynamic_repo(UpgradeRepo)

    try do
      group =
        UpgradeRepo.insert!(%GroupStay.Group{
          group_id: "existing",
          guest_id: "guest",
          property_id: "hotel",
          booked_on: ~D[2026-12-31],
          arrival_on: ~D[2027-06-01],
          departure_on: ~D[2027-06-02],
          rate_plan: "flexible",
          policy_version: "flex-14",
          revision: 4,
          rooms: [%{"room_id" => "a", "nightly_rate_cents" => 1000}],
          lodging_total_cents: 1000,
          deposit_due_cents: 200,
          deposit_paid_cents: 75,
          cash_paid_cents: 25,
          credit_paid_cents: 50
        })

      lot =
        UpgradeRepo.insert!(%GroupStay.CreditLot{
          guest_id: "guest",
          source_operation_id: "earlier-cancel",
          remaining_cents: 60,
          expires_on: ~D[2028-01-01]
        })

      allocation =
        UpgradeRepo.insert!(%GroupStay.CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: 50
        })

      Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
      assert UpgradeRepo.get!(GroupStay.Group, group.group_id) == group
      assert UpgradeRepo.get!(GroupStay.CreditLot, lot.id) == lot
      assert UpgradeRepo.get!(GroupStay.CreditAllocation, allocation.id) == allocation
      assert UpgradeRepo.all(GroupStay.Operation) == []
      assert GroupStay.Reservations.get_operation("earlier-cancel") == nil

      [result] =
        GroupStay.Reservations.batch([
          %{
            "operation_id" => "new-cancel",
            "type" => "cancel_group",
            "group_id" => "existing",
            "occurred_on" => "2027-01-01"
          }
        ])

      assert result.refunded_cents == 25
      assert result.revision == 5
      assert GroupStay.Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 110
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end
end
