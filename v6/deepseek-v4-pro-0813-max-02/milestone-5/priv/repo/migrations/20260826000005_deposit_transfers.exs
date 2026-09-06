defmodule GroupStay.Repo.Migrations.DepositTransfers do
  use Ecto.Migration

  def up do
    create table(:transfer_participations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string, null: false

      timestamps()
    end

    create unique_index(:transfer_participations, [:payment_operation_id])
  end

  def down do
    drop table(:transfer_participations)
  end
end
