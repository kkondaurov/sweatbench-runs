defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  @moduledoc """
  The durable finance period close.

  Each applied `close_finance_period` operation records its cutoff in
  `finance_period_closes` — the unique index keeps one close per date, and
  the strictly-later rule is checked against the latest row. Closing a
  period publishes every daily report through the cutoff: their exact
  rendered JSON is frozen into `finance_report_snapshots`, from where the
  endpoint serves them verbatim forever after. Movement rows gain a `late`
  flag marking postings whose date a close moved forward to the first open
  day; reports surface those separately as late adjustments.
  """

  def change do
    alter table(:finance_cash_movements) do
      add :late, :boolean, null: false, default: false
    end

    alter table(:finance_credit_movements) do
      add :late, :boolean, null: false, default: false
    end

    create table(:finance_period_closes) do
      # A cutoff may be closed once; every later close must move past it.
      add :period_end_on, :date, null: false

      timestamps()
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_report_snapshots) do
      add :report_date, :date, null: false
      add :data_json, :text, null: false

      timestamps()
    end

    create unique_index(:finance_report_snapshots, [:report_date])
  end
end
