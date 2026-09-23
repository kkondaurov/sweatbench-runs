defmodule GroupStay.Repo.Migrations.AddFinancePeriodCloses do
  use Ecto.Migration

  def change do
    # Applied `close_finance_period` operations. Each cutoff is later than every earlier one, so
    # the latest close is the one with the latest `period_end_on`.
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    # Set on movements whose posting date a close moved forward to the first open day. Postings
    # written by earlier releases were never moved.
    alter table(:finance_postings) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
