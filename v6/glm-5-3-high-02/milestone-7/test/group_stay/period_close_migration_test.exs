defmodule GroupStay.PeriodCloseMigrationTest do
  @moduledoc """
  Product request 07: upgrading a database created by the previous
  release.

  A dedicated repository over a throwaway SQLite database runs the real
  migrations in order up to the daily-finance-report release, inserts
  rows exactly as that release would have left them, and then runs the
  period-close migration. Existing reporting rows survive, existing
  events default to not late, and the new close tables come to life.
  """

  use ExUnit.Case, async: false

  defmodule LegacyRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  @migrations_dir Path.expand("../../priv/repo/migrations", __DIR__)
  @daily_report_version 20_260_826_050_000
  @now "2026-08-26 00:00:00"

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "group_stay_period_close_migration_#{System.unique_integer([:positive])}.db"
      )

    start_supervised!({LegacyRepo, database: path, pool_size: 1, log: false})
    on_exit(fn -> File.rm_rf(path) end)

    migrate_to(@daily_report_version)
    insert_legacy_data()

    {:ok, path: path}
  end

  # The migrator loads every migration source on each invocation, which
  # redefines modules already in memory; the conflicts are expected here.
  defp migrate_to(version) do
    Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(LegacyRepo, [@migrations_dir], :up, to: version, log: false)
  after
    Code.compiler_options(ignore_module_conflict: false)
  end

  defp migrate_all do
    Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(LegacyRepo, [@migrations_dir], :up, all: true, log: false)
  after
    Code.compiler_options(ignore_module_conflict: false)
  end

  test "keeps reporting rows, defaults existing events to not late, and adds the close tables" do
    migrate_all()

    # The inception point survived untouched.
    assert [[starts_on, operation_id]] =
             LegacyRepo.query!("SELECT starts_on, operation_id FROM finance_reporting").rows

    assert starts_on == "2027-01-01"
    assert operation_id == "op-mig-start"

    # The pre-close event survived and defaults to not late, so earlier
    # movements never surface as late adjustments.
    assert [[posting_date, classification, amount, late]] =
             LegacyRepo.query!(
               "SELECT posting_date, classification, amount_cents, late FROM finance_events"
             ).rows

    assert posting_date == "2027-01-02"
    assert classification == "received"
    assert amount == 5000
    # SQLite stores booleans as integers: 0 is false.
    assert late in [0, false]

    # A close can be recorded and a report published through the new
    # tables.
    LegacyRepo.query!(
      """
      INSERT INTO finance_period_closes (period_end_on, operation_id, inserted_at, updated_at)
      VALUES ('2027-01-10', 'op-mig-close', ?, ?)
      """,
      [@now, @now]
    )

    LegacyRepo.query!(
      """
      INSERT INTO finance_closed_reports (report_on, data, closed_by_operation_id, inserted_at, updated_at)
      VALUES ('2027-01-10', '{"date":"2027-01-10","status":"closed"}', 'op-mig-close', ?, ?)
      """,
      [@now, @now]
    )

    assert [[period_end_on]] =
             LegacyRepo.query!("SELECT period_end_on FROM finance_period_closes").rows

    assert period_end_on == "2027-01-10"

    assert [[data]] = LegacyRepo.query!("SELECT data FROM finance_closed_reports").rows
    assert data == "{\"date\":\"2027-01-10\",\"status\":\"closed\"}"
  end

  # -- legacy data ------------------------------------------------------------

  defp insert_legacy_data do
    LegacyRepo.query!(
      """
      INSERT INTO finance_reporting (singleton, starts_on, operation_id, opening_position, inserted_at, updated_at)
      VALUES (true, '2027-01-01', 'op-mig-start', '{"cash":{},"credit_liability_cents":0}', ?, ?)
      """,
      [@now, @now]
    )

    LegacyRepo.query!(
      """
      INSERT INTO finance_events (posting_date, kind, classification, property_id, amount_cents, source_operation_id, inserted_at, updated_at)
      VALUES ('2027-01-02', 'cash', 'received', 'ams-canal', 5000, 'op-mig-pay', ?, ?)
      """,
      [@now, @now]
    )
  end
end
