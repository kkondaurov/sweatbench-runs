defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def up do
    alter table(:finance_events) do
      add :original_posting_date, :date
    end

    execute("""
    UPDATE finance_events
    SET original_posting_date = posting_date
    WHERE original_posting_date IS NULL
    """)

    create table(:finance_period_closes) do
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_report_snapshots) do
      add :report_date, :date, null: false
      add :data_json, :text, null: false
    end

    create unique_index(:finance_report_snapshots, [:report_date])
  end

  def down do
    drop table(:finance_report_snapshots)
    drop table(:finance_period_closes)

    alter table(:finance_events) do
      remove :original_posting_date
    end
  end
end
