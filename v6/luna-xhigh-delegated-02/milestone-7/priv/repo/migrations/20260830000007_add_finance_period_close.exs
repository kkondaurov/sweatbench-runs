defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_movements) do
      add :original_posting_on, :date
    end

    execute(
      "UPDATE finance_movements SET original_posting_on = posting_on",
      "UPDATE finance_movements SET original_posting_on = NULL"
    )

    create table(:finance_period_closes) do
      add :operation_id, :text, null: false
      add :period_end_on, :date, null: false
      add :commit_sequence, :integer, null: false
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_report_snapshots, primary_key: false) do
      add :report_date, :date, primary_key: true
      add :close_period_end_on, :date, null: false
      add :data_json, :text, null: false
    end

    create index(:finance_report_snapshots, [:close_period_end_on])
  end
end
