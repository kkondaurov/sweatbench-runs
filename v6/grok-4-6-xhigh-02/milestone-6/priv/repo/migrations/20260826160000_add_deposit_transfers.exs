defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:cash_payments) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end
  end
end
