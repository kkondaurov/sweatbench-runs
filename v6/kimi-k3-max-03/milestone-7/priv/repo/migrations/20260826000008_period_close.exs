defmodule GroupStay.Repo.Migrations.PeriodClose do
  use Ecto.Migration

  def change do
    # The latest successful close cutoff. Reports on or before this date are
    # published and never change again.
    alter table(:finance_reporting) do
      add :closed_through, :date
    end

    # Marks whether a close moved the event's posting date forward. A marked
    # movement appears in the report's late-adjustment block instead of the
    # ordinary day movements.
    alter table(:finance_events) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
