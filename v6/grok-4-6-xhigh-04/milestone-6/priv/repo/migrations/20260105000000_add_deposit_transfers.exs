defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:payment_transfer_participations, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
    end
  end

  def down do
    drop table(:payment_transfer_participations)
  end
end
