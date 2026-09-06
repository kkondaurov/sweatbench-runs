defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    # Durable finance period closes. Each applied close_finance_period
    # operation records its cutoff here; cutoffs are strictly increasing.
    # Every finance report through the latest cutoff is published (status
    # "closed") and stable, and an operation committing afterwards posts on
    # the day after the latest cutoff at the moment it commits.
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
      add :operation_id, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # A movement whose posting date was moved forward by a close reports in
    # the daily report's late_adjustments block instead of the ordinary
    # movement columns; opening and closing balances use both.
    alter table(:funding_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
