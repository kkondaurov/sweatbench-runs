defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    # One row per applied close. Cutoffs are strictly increasing, so the
    # latest close is also the only one that defines the open period; the
    # unique index backs the singleton-per-date guarantee under concurrency.
    create table(:finance_period_closes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :period_end_on, :date, null: false
      add :operation_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    # Movements whose posting date was pushed past a close's cutoff are
    # flagged when they commit, so reports can break out late adjustments
    # without guessing after the fact.
    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create index(:finance_movements, [:posting_date, :late_adjustment])
  end
end
