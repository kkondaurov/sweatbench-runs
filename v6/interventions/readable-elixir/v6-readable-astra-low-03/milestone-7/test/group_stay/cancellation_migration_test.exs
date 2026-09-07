defmodule GroupStay.CancellationMigrationTest do
  use ExUnit.Case

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "an earlier database upgrades booking policies and active cash without changing settlements" do
    directory = Path.join(File.cwd!(), "tmp/migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    {:ok, test_supervisor} = ExUnit.fetch_test_supervisor()

    on_exit(fn ->
      if Process.alive?(test_supervisor), do: Supervisor.stop(test_supervisor)
      GroupStay.DatabaseFiles.remove_directory!(directory)
    end)

    start_supervised!({UpgradeRepo, database: Path.join(directory, "upgrade.db"), pool_size: 1})
    migrations = Path.join(File.cwd!(), "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_907_000_000, log: false)

    for {id, booked, plan, status, paid, refunded} <- [
          {"old", "2026-12-31", "flexible", "active", 100, 0},
          {"new", "2027-01-01", "flexible", "active", 200, 0},
          {"advance", "2026-12-31", "advance_purchase", "active", 300, 0},
          {"settled", "2026-12-31", "flexible", "cancelled", 0, 400}
        ] do
      Ecto.Adapters.SQL.query!(
        UpgradeRepo,
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on,
          departure_on, rate_plan, status, revision, rooms, lodging_total_cents,
          deposit_due_cents, deposit_paid_cents, refunded_cents, retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-06-01', '2027-06-02', ?, ?, 3, '[]',
          1000, 200, ?, ?, 0)
        """,
        [id, booked, plan, status, paid, refunded]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)

    for {id, policy, cash} <- [
          {"old", "flex-14", 100},
          {"new", "flex-30", 200},
          {"advance", "advance-nonrefundable", 300},
          {"settled", "flex-14", 0}
        ] do
      group = UpgradeRepo.get!(GroupStay.Reservations.Group, id)
      assert group.policy_version == policy
      assert group.cash_paid_cents == cash
      assert group.deposit_paid_cents == cash
      assert group.credit_paid_cents == 0
      assert group.revision == 3
      assert GroupStay.Reservations.Group.to_map(group).policy_version == policy
    end

    assert UpgradeRepo.get!(GroupStay.Reservations.Group, "settled").refunded_cents == 400
    assert UpgradeRepo.aggregate(GroupStay.Operations.Record, :count) == 0
  end
end
