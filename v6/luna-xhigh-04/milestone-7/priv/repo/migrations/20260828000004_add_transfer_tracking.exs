defmodule GroupStay.Repo.Migrations.AddTransferTracking do
  use Ecto.Migration

  def change do
    alter table(:cash_payments) do
      add :transfer_participated, :boolean, null: false, default: false
    end
  end
end
