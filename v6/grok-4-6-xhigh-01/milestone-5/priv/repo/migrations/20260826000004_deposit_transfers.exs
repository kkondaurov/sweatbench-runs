defmodule GroupStay.Repo.Migrations.DepositTransfers do
  use Ecto.Migration

  def change do
    create table(:payment_transfer_flags, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true

      timestamps(type: :utc_datetime)
    end
  end
end
