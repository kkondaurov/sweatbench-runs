defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:payment_states) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end
  end
end
