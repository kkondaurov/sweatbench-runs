defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting) do
      add :latest_closed_on, :date
    end

    alter table(:finance_movements) do
      add :original_posting_on, :date
    end

    execute("UPDATE finance_movements SET original_posting_on = posting_on")

    alter table(:finance_credit_events) do
      add :original_posting_on, :date
    end

    execute("UPDATE finance_credit_events SET original_posting_on = posting_on")

    create table(:finance_reports, primary_key: false) do
      add :date, :date, primary_key: true
      add :data, :map, null: false
    end
  end

  def down do
    drop table(:finance_reports)

    alter table(:finance_credit_events) do
      remove :original_posting_on
    end

    alter table(:finance_movements) do
      remove :original_posting_on
    end

    alter table(:finance_reporting) do
      remove :latest_closed_on
    end
  end
end
