defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def change do
    # One row per successful close_finance_period. The latest period_end_on
    # is the cutoff through which daily reports are published.
    create table(:finance_closes) do
      add :period_end_on, :date, null: false

      timestamps()
    end

    create unique_index(:finance_closes, [:period_end_on])

    # Marks finance events whose posting date was moved forward by a close,
    # so reports can show them separately as late adjustments.
    alter table(:finance_events) do
      add :posted_after_close, :boolean, null: false, default: false
    end
  end
end
