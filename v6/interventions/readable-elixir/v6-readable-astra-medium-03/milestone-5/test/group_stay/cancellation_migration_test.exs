defmodule GroupStay.CancellationMigrationTest do
  use ExUnit.Case, async: false

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "a populated earlier database upgrades without changing balances or revisions" do
    directory = Path.expand("tmp/upgrade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> GroupStay.TestDatabase.remove!(directory) end)

    repo =
      start_supervised!({UpgradeRepo, database: Path.join(directory, "upgrade.db"), pool_size: 1})

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo)
    end)

    migrations = GroupStay.TestDatabase.migrations()
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_907_000_000, log: false)

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
        VALUES (?, 'guest', 'hotel', ?, '2027-03-01', '2027-03-02', ?, 'active', 7,
          '[{"room_id":"room","nightly_rate_cents":1000}]', 1000, 200, 100)
        """,
        [id, booked, plan]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)

    for {id, policy, deadline} <- [
          {"old", "flex-14", ~D[2027-02-15]},
          {"new", "flex-30", ~D[2027-01-30]},
          {"advance", "advance-nonrefundable", nil}
        ] do
      data =
        UpgradeRepo.get!(GroupStay.Reservations.Group, id)
        |> GroupStay.Reservations.Group.public_data()

      assert data.policy_version == policy
      assert data.refundable_until == deadline
      assert data.revision == 7
      assert data.cash_paid_cents == 100
      assert data.credit_paid_cents == 0
      assert data.outstanding_deposit_cents == 100
    end

    assert UpgradeRepo.aggregate(GroupStay.Operations.Record, :count) == 0

    stop_supervised!(UpgradeRepo)
  end
end
