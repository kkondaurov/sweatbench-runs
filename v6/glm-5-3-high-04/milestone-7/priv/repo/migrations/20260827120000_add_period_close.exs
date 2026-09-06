defmodule GroupStay.Repo.Migrations.AddPeriodClose do
  use Ecto.Migration

  def up do
    # One row per successful finance period close, in close order. The
    # latest period_end_on is the reporting cutoff: reports through it are
    # published and stable, and operations processed after it post on the
    # first following day.
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
      add :operation_id, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_period_closes, [:period_end_on])

    # The published daily report of every closed day, snapshotted when the
    # period was closed: the byte-for-byte stable `data` value returned for
    # that day forever after.
    create table(:finance_report_snapshots) do
      add :date, :date, null: false
      add :data, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_report_snapshots, [:date])

    # True when a close moved the movement's posting date forward: the
    # movement posts on the first open day and appears in the report's
    # late_adjustments block instead of its ordinary movement columns.
    alter table(:finance_movements) do
      add :moved_by_close, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:finance_movements) do
      remove :moved_by_close
    end

    drop unique_index(:finance_report_snapshots, [:date])
    drop table(:finance_report_snapshots)

    drop index(:finance_period_closes, [:period_end_on])
    drop table(:finance_period_closes)
  end
end
