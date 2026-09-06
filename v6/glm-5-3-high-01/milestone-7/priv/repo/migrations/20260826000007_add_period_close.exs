defmodule GroupStay.Repo.Migrations.AddPeriodClose do
  use Ecto.Migration

  def up do
    # The durable record of each successful finance period close. Cutoffs are
    # strictly increasing, and the unique index on `period_end_on` keeps a
    # concurrent duplicate cutoff from landing a second time.
    create table(:finance_period_closes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :period_end_on, :date, null: false
      add :closed_by_operation_id, :string, null: false

      timestamps()
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    # Movements whose posting date was moved forward by a close are reported
    # as late adjustments instead of ordinary movements. Rows written by
    # earlier releases are ordinary movements.
    alter table(:finance_movements) do
      add :late, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:finance_movements) do
      remove :late
    end

    drop table(:finance_period_closes)
  end
end
