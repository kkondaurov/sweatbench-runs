defmodule GroupStay.Repo.Migrations.CreateFinancePeriodCloses do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting_states) do
      # The latest successful close's cutoff, or null before any close.
      # Reports for dates at or before this stay byte-for-byte stable.
      add :closed_through_on, :date
    end

    alter table(:finance_journal) do
      # Set on movements whose posting date a close moved forward to the
      # first open day. Such movements are reported in a day's
      # `late_adjustments` instead of its ordinary movement columns.
      add :late, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:finance_journal) do
      remove :late
    end

    alter table(:finance_reporting_states) do
      remove :closed_through_on
    end
  end
end
