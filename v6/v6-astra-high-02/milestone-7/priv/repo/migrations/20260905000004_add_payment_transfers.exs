defmodule GroupStay.Repo.Migrations.AddPaymentTransfers do
  use Ecto.Migration

  def change do
    create table(:payment_transfers, primary_key: false) do
      add :payment_operation_id,
          references(:operations, column: :operation_id, type: :string),
          primary_key: true
    end
  end
end
