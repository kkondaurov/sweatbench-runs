defmodule GroupStay.Repo.Migrations.PeriodClose do
  use Ecto.Migration

  def change do
    # Every successful close advances the published cutoff; cutoffs are strictly
    # increasing, so the unique index also guards concurrent equal cutoffs.
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    # One materialized report per closed date. A closed report is served from
    # this row verbatim, so its data stays byte-for-byte stable across later
    # operations, later closes, and process restarts.
    create table(:finance_closed_reports, primary_key: false) do
      add :date, :date, primary_key: true
      add :data, :map, null: false

      timestamps(type: :utc_datetime)
    end

    alter table(:finance_movements) do
      # True when a close moved the movement's posting date forward; such
      # movements are reported as late adjustments instead of ordinary
      # movements on the day they post.
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
