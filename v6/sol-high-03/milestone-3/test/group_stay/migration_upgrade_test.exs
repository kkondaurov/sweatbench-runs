defmodule GroupStay.MigrationUpgradeRepo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3
end

defmodule GroupStay.MigrationUpgradeTest do
  use ExUnit.Case, async: false

  alias GroupStay.MigrationUpgradeRepo

  @old_version 20_260_825_000_000

  test "upgrades populated operational-core databases and backfills immutable policy and cash" do
    database =
      Path.join(File.cwd!(), "migration_upgrade_#{System.unique_integer([:positive])}.db")

    Application.put_env(:group_stay, MigrationUpgradeRepo,
      database: database,
      pool_size: 1,
      log: false
    )

    on_exit(fn ->
      Application.delete_env(:group_stay, MigrationUpgradeRepo)
      File.rm(database)
      File.rm(database <> "-shm")
      File.rm(database <> "-wal")
    end)

    start_supervised!(MigrationUpgradeRepo)
    migrations = Path.expand("../../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(MigrationUpgradeRepo, migrations, :up, to: @old_version)

    insert_legacy_group("old-flex", "2026-12-31", "flexible", 125)
    insert_legacy_group("new-flex", "2027-01-01", "flexible", 250)
    insert_legacy_group("advance", "2027-01-01", "advance_purchase", 375)

    Ecto.Migrator.run(MigrationUpgradeRepo, migrations, :up, all: true)

    rows =
      Ecto.Adapters.SQL.query!(
        MigrationUpgradeRepo,
        """
        SELECT group_id, policy_version, deposit_paid_cents, cash_paid_cents,
               credit_paid_cents, cash_converted_to_credit_cents
          FROM groups
         ORDER BY group_id
        """,
        []
      ).rows

    assert rows == [
             ["advance", "advance-nonrefundable", 375, 375, 0, 0],
             ["new-flex", "flex-30", 250, 250, 0, 0],
             ["old-flex", "flex-14", 125, 125, 0, 0]
           ]

    assert Ecto.Adapters.SQL.query!(
             MigrationUpgradeRepo,
             "SELECT COUNT(*) FROM partner_operations",
             []
           ).rows == [[0]]
  end

  defp insert_legacy_group(group_id, booked_on, rate_plan, paid) do
    Ecto.Adapters.SQL.query!(
      MigrationUpgradeRepo,
      """
      INSERT INTO groups (
        group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, status, revision, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, cash_held_cents
      ) VALUES (?, 'legacy-guest', 'legacy-property', ?, '2027-04-01', '2027-04-02',
                ?, 'active', 2, 1000, 500, ?, ?)
      """,
      [group_id, booked_on, rate_plan, paid, paid]
    )
  end
end
