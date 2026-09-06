defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    # Once any funding from a cash payment has participated in a deposit
    # transfer, that payment's reconciliation statement reports its held cash
    # per group. The flag records the participation permanently, even after
    # none of the payment's cash remains held.
    alter table(:ledger_entries) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end
  end
end
