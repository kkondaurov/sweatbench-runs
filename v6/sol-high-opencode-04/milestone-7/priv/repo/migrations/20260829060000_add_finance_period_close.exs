defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting) do
      add :closed_through, :date
    end

    alter table(:finance_events) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    execute("""
    UPDATE finance_events
    SET posting_on = printf(
      '%012d',
      CAST(julianday(posting_on) - julianday('0000-01-01') AS INTEGER)
    )
    """)
  end

  def down do
    execute("""
    UPDATE finance_events
    SET posting_on = date(CAST(posting_on AS INTEGER) + julianday('0000-01-01'))
    """)

    alter table(:finance_events) do
      remove :late_adjustment
    end

    alter table(:finance_reporting) do
      remove :closed_through
    end
  end
end
