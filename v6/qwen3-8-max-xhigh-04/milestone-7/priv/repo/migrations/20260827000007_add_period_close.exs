defmodule GroupStay.Repo.Migrations.AddPeriodClose do
  use Ecto.Migration

  def change do
    create table(:finance_period_closes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_period_closes, [:period_end_on])

    create table(:finance_closed_reports, primary_key: false) do
      add :date, :date, primary_key: true
      add :data, :string, null: false

      timestamps(type: :utc_datetime)
    end

    alter table(:finance_movements) do
      add :late, :boolean, default: false, null: false
    end
  end
end
