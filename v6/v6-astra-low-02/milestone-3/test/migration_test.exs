defmodule GroupStay.MigrationTest do
  use ExUnit.Case, async: false

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "an earlier database upgrades policies and preserves balances and revisions" do
    path = Path.expand("migration-test-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Path.expand("priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_000, log: false)

    for {id, booked, plan} <- [
          {"old", "2026-12-31", "flexible"},
          {"new", "2027-01-01", "flexible"},
          {"advance", "2026-12-31", "advance_purchase"}
        ] do
      Ecto.Adapters.SQL.query!(
        UpgradeRepo,
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on,
          departure_on, rate_plan, status, revision, rooms, lodging_total_cents,
          deposit_due_cents, deposit_paid_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-03-01', '2027-03-02', ?, 'active', 7, '[]', 1000, 200, 100)
        """,
        [id, booked, plan]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)

    assert UpgradeRepo.aggregate(GroupStay.Operation, :count) == 0

    for {id, policy} <- [
          {"old", "flex-14"},
          {"new", "flex-30"},
          {"advance", "advance-nonrefundable"}
        ] do
      group = UpgradeRepo.get!(GroupStay.Group, id)
      assert group.policy_version == policy
      assert group.revision == 7
      assert group.deposit_paid_cents == 100
      assert group.cash_paid_cents == 100
      assert group.credit_paid_cents == 0
      assert group.credit_allocations == []
    end
  end
end
