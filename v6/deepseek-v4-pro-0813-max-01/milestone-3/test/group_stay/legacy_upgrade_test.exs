defmodule GroupStay.LegacyUpgradeTest do
  use ExUnit.Case, async: false

  defmodule LegacyRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  alias GroupStay.LegacyUpgradeTest.LegacyRepo

  @migrations "priv/repo/migrations"

  test "a database built by the earlier release upgrades and receives the right policies" do
    database =
      Path.join(
        System.tmp_dir!(),
        "group_stay_legacy_#{System.unique_integer([:positive])}.db"
      )

    # Delete any leftovers so the run starts from an empty database.
    File.rm(database)

    start_supervised!({LegacyRepo, database: database, busy_timeout: 30_000})
    on_exit(fn -> File.rm(database) end)

    # Build the schema of the earlier release only.
    Ecto.Migrator.run(LegacyRepo, @migrations, :up, to: 20_260_801_000_000)

    Ecto.Adapters.SQL.query!(
      LegacyRepo,
      """
      INSERT INTO groups (id, group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
                          rate_plan, status, revision, deposit_paid_cents, refunded_cents,
                          retained_cents, inserted_at, updated_at)
      VALUES
        ('11111111-1111-1111-1111-111111111111', 'legacy-flex-14', 'guest-1', 'ams-canal',
         '2026-12-31', '2027-06-30', '2027-07-03', 'flexible', 'active', 3, 1000, 0, 0,
         '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
        ('22222222-2222-2222-2222-222222222222', 'legacy-flex-30', 'guest-2', 'ams-canal',
         '2027-01-01', '2027-03-31', '2027-04-03', 'flexible', 'cancelled', 4, 500, 100, 400,
         '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
        ('33333333-3333-3333-3333-333333333333', 'legacy-advance', 'guest-3', 'ams-canal',
         '2027-05-01', '2027-08-01', '2027-08-03', 'advance_purchase', 'active', 2, 9000, 0, 0,
         '2026-01-01 00:00:00', '2026-01-01 00:00:00')
      """,
      []
    )

    # Upgrading to the new release backfills policies and adds credit tables.
    Ecto.Migrator.run(LegacyRepo, @migrations, :up, to: 20_260_826_000_000)

    rows =
      Ecto.Adapters.SQL.query!(
        LegacyRepo,
        """
        SELECT group_id, policy_version, cash_paid_cents, credit_paid_cents,
               cash_converted_to_credit_cents
        FROM groups
        ORDER BY group_id
        """,
        []
      ).rows

    assert rows == [
             ["legacy-advance", "advance-nonrefundable", 9000, 0, 0],
             ["legacy-flex-14", "flex-14", 1000, 0, 0],
             ["legacy-flex-30", "flex-30", 500, 0, 0]
           ]

    tables =
      Ecto.Adapters.SQL.query!(
        LegacyRepo,
        """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name IN ('credit_lots', 'credit_applications')
        ORDER BY name
        """,
        []
      ).rows

    assert tables == [["credit_applications"], ["credit_lots"]]
  end
end
