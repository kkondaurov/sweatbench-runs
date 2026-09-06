defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    create table(:cash_payment_transfers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string, null: false
      add :transfer_operation_id, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cash_payment_transfers, [:payment_operation_id])
    create index(:cash_payment_transfers, [:transfer_operation_id])
  end
end
