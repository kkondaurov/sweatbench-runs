defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    # The durable record of a signed-off finance period. One row per applied
    # `close_finance_period`; every report through the latest `period_end_on`
    # is published and must never change again.
    create table(:finance_period_closes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    # Marks a movement whose posting date was pushed onto the first open day by
    # a close. Such movements surface in the day's `late_adjustments` block.
    alter table(:finance_movements) do
      add :moved_by_close, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:finance_movements) do
      remove :moved_by_close
    end

    drop table(:finance_period_closes)
  end
end
