defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    # One durable record per successful finance period close, in commit order.
    # A close is only applied strictly later than the latest recorded cutoff,
    # so the newest row always carries the latest one.
    create table(:finance_period_closes, primary_key: false) do
      add :id, :integer, primary_key: true
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:operation_id])

    # The published daily report of one date, frozen when a close covered it.
    # Later operations never rewrite a closed day: reading a date within a
    # closed period returns this stored data unchanged, across later
    # operations, later closes, and process restarts.
    create table(:finance_report_snapshots, primary_key: false) do
      add :id, :integer, primary_key: true
      add :date, :date, null: false
      add :data, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_report_snapshots, [:date])

    alter table(:finance_movements) do
      # Whether the close cutoff moved this movement's posting date forward:
      # such movements are reported in the report's late_adjustments block
      # instead of its ordinary movement columns.
      add :late, :boolean, null: false, default: false
    end
  end
end
