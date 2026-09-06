defmodule GroupStay.MigrationTest do
  use ExUnit.Case, async: false

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "an earlier database upgrades policy and cash without changing existing settlements" do
    path = Path.expand("_build/migration-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> Enum.each([path, path <> "-shm", path <> "-wal"], &File.rm/1) end)
    start_supervised!({MigrationRepo, database: path, pool_size: 1})
    migrations = Path.expand("priv/repo/migrations")
    Ecto.Migrator.run(MigrationRepo, migrations, :up, to: 20_260_905_000_000, log: false)

    for {id, booked, plan, status, paid, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 100, 0, 0},
          {"new", "2027-01-01", "flexible", "active", 200, 0, 0},
          {"advance", "2026-12-31", "advance_purchase", "cancelled", 0, 0, 300},
          {"refunded", "2026-12-31", "flexible", "cancelled", 0, 400, 0}
        ] do
      Ecto.Adapters.SQL.query!(
        MigrationRepo,
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, rooms, revision, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, refunded_cents, retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2028-06-01', '2028-06-02', ?, ?, '[{"room_id":"a","nightly_rate_cents":1000}]', 3, 1000, 200, ?, ?, ?)
        """,
        [id, booked, plan, status, paid, refunded, retained]
      )
    end

    Ecto.Migrator.run(MigrationRepo, migrations, :up, all: true, log: false)
    old = MigrationRepo.get!(GroupStay.Group, "old")
    assert old.policy_version == "flex-14"
    assert old.cash_paid_cents == old.deposit_paid_cents
    assert old.cash_paid_cents == 100
    assert old.revision == 3
    assert MigrationRepo.get!(GroupStay.Group, "new").policy_version == "flex-30"
    advance = MigrationRepo.get!(GroupStay.Group, "advance")
    assert advance.policy_version == "advance-nonrefundable"
    assert advance.retained_cents == 300
    assert advance.cash_paid_cents == 0
    assert MigrationRepo.get!(GroupStay.Group, "refunded").refunded_cents == 400
    assert MigrationRepo.all(GroupStay.CreditLot) == []
    assert MigrationRepo.all(GroupStay.Operation) == []
  end
end
