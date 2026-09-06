defmodule GroupStay.Repo.Migrations.AddPeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting) do
      add :latest_close_on, :date
    end

    alter table(:finance_movements) do
      add :original_posting_on, :date
    end

    execute("""
    UPDATE finance_movements
    SET original_posting_on = posting_on
    WHERE original_posting_on IS NULL
    """)

    create table(:finance_reports, primary_key: false) do
      add :report_date, :date, primary_key: true
      add :data, :map, null: false
    end
  end

  def down do
    drop table(:finance_reports)

    alter table(:finance_movements) do
      remove :original_posting_on
    end

    alter table(:finance_reporting) do
      remove :latest_close_on
    end
  end
end
