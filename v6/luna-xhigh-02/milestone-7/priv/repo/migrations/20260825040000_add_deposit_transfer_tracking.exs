defmodule GroupStay.Repo.Migrations.AddDepositTransferTracking do
  use Ecto.Migration

  def change do
    alter table(:cash_payment_records) do
      add :transfer_participated, :boolean, null: false, default: false
    end
  end
end
