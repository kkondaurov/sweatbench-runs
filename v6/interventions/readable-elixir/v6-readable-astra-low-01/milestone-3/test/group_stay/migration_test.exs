defmodule GroupStay.MigrationTest do
  use ExUnit.Case, async: false

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "an earlier database upgrades booking policies without changing cash or revisions" do
    directory = Path.expand("tmp/migration-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(directory)

    repo =
      start_supervised!({UpgradeRepo, database: Path.join(directory, "upgrade.db"), pool_size: 1})

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo)
      GroupStay.DatabaseFiles.remove!(directory)
    end)

    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_907_000_000, log: false)

    for {id, booked, plan} <- [
          {"old", "2026-12-31", "flexible"},
          {"new", "2027-01-01", "flexible"},
          {"advance", "2026-12-31", "advance_purchase"}
        ] do
      Ecto.Adapters.SQL.query!(
        UpgradeRepo,
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents, deposit_paid_cents)
        VALUES (?, 'guest', 'hotel', ?, '2028-04-01', '2028-04-02', ?, 'active', 3, '[]', 1000, 200, 100)
        """,
        [id, booked, plan]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)

    assert UpgradeRepo.aggregate(GroupStay.Operations.Record, :count) == 0

    for {id, policy, cutoff} <- [
          {"old", "flex-14", ~D[2028-03-18]},
          {"new", "flex-30", ~D[2028-03-02]},
          {"advance", "advance-nonrefundable", nil}
        ] do
      group = UpgradeRepo.get!(GroupStay.Reservations.Group, id)

      assert %{
               policy_version: ^policy,
               refundable_until: ^cutoff,
               revision: 3,
               cash_paid_cents: 100,
               credit_paid_cents: 0
             } = GroupStay.Reservations.Group.public(group)
    end
  end
end
