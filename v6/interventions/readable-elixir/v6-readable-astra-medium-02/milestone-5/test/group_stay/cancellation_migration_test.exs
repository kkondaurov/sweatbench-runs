defmodule GroupStay.CancellationMigrationTest do
  use ExUnit.Case, async: false

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "an earlier database preserves cash, revisions, and booking policy when upgraded" do
    token = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    database = Path.expand("_build/migration-#{token}.db")

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
    end)

    start_supervised!({MigrationRepo, database: database, pool_size: 1})
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(MigrationRepo, migrations, :up, to: 20_260_907_000_000, log: false)

    for {id, booked, plan, status, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 0, 0},
          {"new", "2027-01-01", "flexible", "active", 0, 0},
          {"advance", "2026-12-31", "advance_purchase", "active", 0, 0},
          {"refunded", "2026-12-31", "flexible", "cancelled", 100, 0},
          {"retained", "2026-12-31", "flexible", "cancelled", 0, 100}
        ] do
      MigrationRepo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, refunded_cents, retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-06-01', '2027-06-02', ?, ?, 7,
          '[{"room_id":"room","nightly_rate_cents":1000}]', 1000, ?, 100, ?, ?)
        """,
        [id, booked, plan, status, if(status == "active", do: 200, else: 0), refunded, retained]
      )
    end

    Ecto.Migrator.run(MigrationRepo, migrations, :up, all: true, log: false)

    for {id, version, deadline} <- [
          {"old", "flex-14", ~D[2027-05-18]},
          {"new", "flex-30", ~D[2027-05-02]},
          {"advance", "advance-nonrefundable", nil},
          {"refunded", "flex-14", ~D[2027-05-18]},
          {"retained", "flex-14", ~D[2027-05-18]}
        ] do
      group = MigrationRepo.get!(GroupStay.Reservations.Group, id)

      assert %{
               revision: 7,
               cash_paid_cents: 100,
               deposit_paid_cents: 100,
               credit_paid_cents: 0,
               cash_converted_to_credit_cents: 0,
               policy_version: ^version
             } = group

      assert GroupStay.Reservations.Group.to_map(group).refundable_until == deadline
    end

    assert MigrationRepo.get!(GroupStay.Reservations.Group, "refunded").refunded_cents == 100
    assert MigrationRepo.get!(GroupStay.Reservations.Group, "retained").retained_cents == 100
    assert MigrationRepo.all(GroupStay.Reservations.CreditLot) == []
    assert MigrationRepo.all(GroupStay.Reservations.CreditAllocation) == []
    assert MigrationRepo.all(GroupStay.Operations.Record) == []
    stop_supervised!(MigrationRepo)
  end
end
