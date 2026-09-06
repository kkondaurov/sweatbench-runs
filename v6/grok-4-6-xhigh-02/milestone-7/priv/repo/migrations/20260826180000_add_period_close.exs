defmodule GroupStay.Repo.Migrations.AddPeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :closed_through, :date
    end

    alter table(:finance_events) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_closed_reports, primary_key: false) do
      add :date, :date, primary_key: true
      add :data, :map, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
