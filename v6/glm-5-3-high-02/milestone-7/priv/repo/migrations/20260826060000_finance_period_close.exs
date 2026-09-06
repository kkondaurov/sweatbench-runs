defmodule GroupStay.Repo.Migrations.FinancePeriodClose do
  use Ecto.Migration

  @moduledoc """
  Product request 07: the finance period close.

  `finance_events` gains a `late` flag marking movements whose posting date
  was moved forward by a close — the source of the daily report's
  `late_adjustments` block. Existing rows default to not late.

  `finance_period_closes` records each successful close: its cutoff date
  and the partner operation that committed it.

  `finance_closed_reports` stores the published `data` value of every
  daily report through a close's cutoff. A stored report is returned
  verbatim forever after, which keeps published daily figures
  byte-for-byte stable across later operations, later closes, and process
  restarts.
  """

  def up do
    alter table(:finance_events) do
      # True when a close moved this movement's posting date forward.
      add :late, :boolean, null: false, default: false
    end

    create table(:finance_period_closes) do
      # The last date of the closed period.
      add :period_end_on, :date, null: false
      # The close partner operation that committed this row.
      add :operation_id, :string, null: false

      timestamps()
    end

    create index(:finance_period_closes, [:period_end_on])

    create table(:finance_closed_reports) do
      # The report date this row publishes.
      add :report_on, :date, null: false
      # The report's `data` value, frozen at close time.
      add :data, :text, null: false
      # The close operation that published this report.
      add :closed_by_operation_id, :string, null: false

      timestamps()
    end

    create unique_index(:finance_closed_reports, [:report_on])
  end

  def down do
    drop table(:finance_closed_reports)
    drop table(:finance_period_closes)

    alter table(:finance_events) do
      remove :late
    end
  end
end
