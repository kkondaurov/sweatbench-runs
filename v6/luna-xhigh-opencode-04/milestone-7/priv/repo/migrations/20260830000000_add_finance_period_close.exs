defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_report_events) do
      add :original_posting_on, :date, null: false, default: "1970-01-01"
    end

    execute """
    UPDATE finance_report_events
    SET original_posting_on = posting_on
    """

    create table(:finance_period_closes) do
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false
    end

    create unique_index(:finance_period_closes, [:operation_id])
    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_reports) do
      add :report_date, :date, null: false
      add :status, :string, null: false
      add :data, :map, null: false
    end

    create unique_index(:finance_reports, [:report_date])
  end

  def down do
    drop unique_index(:finance_reports, [:report_date])
    drop table(:finance_reports)

    drop unique_index(:finance_period_closes, [:period_end_on])
    drop unique_index(:finance_period_closes, [:operation_id])
    drop table(:finance_period_closes)

    alter table(:finance_report_events) do
      remove :original_posting_on
    end
  end
end
