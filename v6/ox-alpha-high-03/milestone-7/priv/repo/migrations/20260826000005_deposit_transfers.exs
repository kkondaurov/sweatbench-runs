defmodule GroupStay.Repo.Migrations.DepositTransfers do
  use Ecto.Migration

  def up do
    create table(:payment_transfers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_transfers, [:operation_id])
  end

  def down do
    drop table(:payment_transfers)
  end
end
