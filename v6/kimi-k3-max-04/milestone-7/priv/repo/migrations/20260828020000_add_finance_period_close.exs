defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  @moduledoc """
  Finance period close (docs/requests/07).

  `reporting_state.closed_through` records the latest successful close; a
  `close_finance_period` operation only applies strictly later than it.

  Once a close is processed, the computed report for every date through the
  cutoff is materialized into `closed_reports`, so a closed day's `data` is
  byte-for-byte stable across later operations, later closes, and process
  restarts. Expiry synthesis and late-adjustment classification are resolved
  at close time.

  A movement whose posting date was moved forward by a close records that on
  `finance_movements.late`, so open reports can classify its contributions
  into the `late_adjustments` block while ordinary movement columns keep
  their plain values.
  """
  use Ecto.Migration

  def up do
    alter table(:reporting_state) do
      add :closed_through, :date
    end

    alter table(:finance_movements) do
      add :late, :boolean, null: false, default: false
    end

    create table(:closed_reports, primary_key: false) do
      add :date, :date, primary_key: true
      add :data, :map, null: false

      timestamps()
    end
  end

  def down do
    drop(table(:closed_reports))

    alter table(:finance_movements) do
      remove :late
    end

    alter table(:reporting_state) do
      remove :closed_through
    end
  end
end
