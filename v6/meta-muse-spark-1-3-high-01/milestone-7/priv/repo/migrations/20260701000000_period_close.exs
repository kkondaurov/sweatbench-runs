defmodule GroupStay.Repo.Migrations.PeriodClose do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
      add :closed_by_operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_report_snapshots) do
      add :report_date, :date, null: false
      add :data_json, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_report_snapshots, [:report_date])

    alter table(:finance_cash_movements) do
      add :intended_post_date, :date
    end

    alter table(:finance_credit_movements) do
      add :intended_post_date, :date
    end
  end
end
