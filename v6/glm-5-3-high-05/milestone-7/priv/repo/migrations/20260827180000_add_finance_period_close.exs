defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    # The durable record of each successful finance period close. The latest
    # `period_end_on` is the reporting cutoff: every report through it is
    # published, and movements processed after it post on the first open day.
    create table(:finance_closes) do
      add :period_end_on, :date, null: false

      timestamps()
    end

    # The published daily reports. One row per closed day, written when the
    # close publishing that day is processed: the stored JSON is the exact
    # `data` value the API returns, byte-for-byte stable across later
    # operations, later closes, and restarts.
    create table(:finance_report_snapshots, primary_key: false) do
      add :date, :date, primary_key: true
      add :data, :text, null: false

      timestamps()
    end

    # A movement whose posting date a close moved forward into the open
    # period. Such movements are reported as late adjustments rather than
    # ordinary movements on their posting date.
    alter table(:finance_events) do
      add :late, :boolean, null: false, default: false
    end
  end
end
