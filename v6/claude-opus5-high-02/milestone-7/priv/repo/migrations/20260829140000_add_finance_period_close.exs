defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    # Every cutoff a controller has signed off. Closes only ever move forward, so the latest row
    # is the boundary between the published period and the open one.
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    # Whether a close pushed the movement's posting date past the date it would otherwise have
    # posted to. Movements committed before this release were never moved, so they are not late.
    alter table(:finance_movements) do
      add :late, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:finance_movements) do
      remove :late
    end

    drop unique_index(:finance_period_closes, [:period_end_on])
    drop table(:finance_period_closes)
  end
end
