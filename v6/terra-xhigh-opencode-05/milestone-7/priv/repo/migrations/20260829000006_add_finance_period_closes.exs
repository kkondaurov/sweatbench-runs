defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def up do
    alter table(:finance_postings) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    alter table(:finance_credit_expiry_schedules) do
      add :late_adjustment, :boolean, null: false, default: false
      add :reported_amount_cents, :integer, null: false, default: 0
    end

    execute("UPDATE finance_credit_expiry_schedules SET reported_amount_cents = amount_cents")

    create table(:finance_period_closes) do
      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :period_end_on, :date, null: false

      timestamps()
    end

    create unique_index(:finance_period_closes, [:reporting_start_id, :period_end_on])

    create table(:finance_closed_daily_reports) do
      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :date, :date, null: false
      add :data, :text, null: false

      timestamps()
    end

    create unique_index(:finance_closed_daily_reports, [:reporting_start_id, :date])
  end

  def down do
    drop table(:finance_closed_daily_reports)
    drop table(:finance_period_closes)

    alter table(:finance_credit_expiry_schedules) do
      remove :reported_amount_cents
      remove :late_adjustment
    end

    alter table(:finance_postings) do
      remove :late_adjustment
    end
  end
end
