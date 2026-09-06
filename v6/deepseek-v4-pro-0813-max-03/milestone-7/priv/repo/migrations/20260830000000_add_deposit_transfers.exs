defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    create table(:transfer_participations) do
      add :payment_operation_id, :string, null: false

      timestamps()
    end

    create unique_index(:transfer_participations, [:payment_operation_id])

    create table(:legacy_funding_moves) do
      add :origin_group_id, references(:groups, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:legacy_funding_moves, [:origin_group_id])
  end
end
