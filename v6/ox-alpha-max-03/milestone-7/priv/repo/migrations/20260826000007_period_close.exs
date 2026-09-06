defmodule GroupStay.Repo.Migrations.PeriodClose do
  use Ecto.Migration

  def up do
    create table(:finance_period_closes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_closed_reports, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :report_date, :date, null: false

      # The published report exactly as first served for the date.
      add :data, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_closed_reports, [:report_date])

    alter table(:finance_events) do
      # True when a period close pushed the operation's posting date forward,
      # so the movement belongs to the report's late adjustments.
      add :late_adjustment, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:finance_events) do
      remove :late_adjustment
    end

    drop table(:finance_closed_reports)
    drop table(:finance_period_closes)
  end
end
