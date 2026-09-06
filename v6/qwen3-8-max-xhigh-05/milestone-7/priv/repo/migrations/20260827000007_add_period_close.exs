defmodule GroupStay.Repo.Migrations.AddPeriodClose do
  use Ecto.Migration

  def change do
    alter table(:finance_reporting) do
      add :latest_close_on, :date
    end

    alter table(:finance_report_movements) do
      add :late, :boolean, null: false, default: false
    end
  end
end
