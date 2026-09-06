defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    # Each accepted close records its cutoff; the latest one bounds the open
    # reporting period used to choose posting dates.
    create table(:finance_closes) do
      add :period_end_on, :date, null: false
      add :operation_id, :string, null: false

      timestamps()
    end

    create unique_index(:finance_closes, [:period_end_on])

    # Reports frozen by a close are stored as published JSON so their `data`
    # value never changes across later operations, closes, or restarts.
    create table(:finance_report_days) do
      add :report_date, :date, null: false
      add :data, :text, null: false

      timestamps()
    end

    create unique_index(:finance_report_days, [:report_date])

    # Movements whose posting date a close moved forward surface separately
    # in each report's `late_adjustments`. The flag is fixed when the movement
    # commits because a later close never moves it again.
    alter table(:finance_movements) do
      add :late, :boolean, null: false, default: false
    end
  end
end
