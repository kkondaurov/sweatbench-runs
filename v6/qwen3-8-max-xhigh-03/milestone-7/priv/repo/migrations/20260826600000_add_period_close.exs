defmodule GroupStay.Repo.Migrations.AddPeriodClose do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes) do
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_published_reports, primary_key: false) do
      add :report_date, :date, primary_key: true
      add :data, :text, null: false

      timestamps(type: :utc_datetime)
    end

    alter table(:finance_movements) do
      add :natural_posting_date, :date
    end

    execute "UPDATE finance_movements SET natural_posting_date = posting_date", ""

    create index(:finance_movements, [:natural_posting_date])
  end
end
