defmodule GroupStay.Repo.Migrations.CreateDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:payments) do
      # Set on a cash payment the first time any of its held cash is moved
      # by a deposit transfer. Once set its payment statement additionally
      # reports where the payment is currently held, by group.
      add :participated_in_transfer, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:payments) do
      remove :participated_in_transfer
    end
  end
end
