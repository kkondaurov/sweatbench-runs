defmodule GroupStay.Repo.Migrations.AddPeriodClose do
  use Ecto.Migration

  def change do
    # Every movement records at commit time whether a close moved its posting
    # date forward into the open period. Rows from before closes existed post
    # naturally and are ordinary movements.
    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    # One row per successful close: the cutoff it published reports through
    # and the partner operation that closed the period. Cutoffs are strictly
    # increasing, so the row with the latest `period_end_on` separates the
    # published period from the open period.
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    # One snapshot per published day: the daily report's frozen `data` value
    # as computed when the close covering it was processed. Later operations
    # and later closes never rewrite it.
    create table(:finance_closed_reports) do
      add :date, :date, null: false
      add :data, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_closed_reports, [:date])
  end
end
