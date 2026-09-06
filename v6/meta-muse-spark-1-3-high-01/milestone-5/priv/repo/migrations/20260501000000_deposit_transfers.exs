defmodule GroupStay.Repo.Migrations.DepositTransfers do
  use Ecto.Migration

  def change do
    create table(:payment_transfer_flags) do
      add :payment_operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_transfer_flags, [:payment_operation_id])

    create table(:payment_settlement_shares) do
      add :payment_operation_id, :string, null: false
      add :settling_group_db_id, references(:groups, on_delete: :delete_all)
      add :settling_group_id, :string, null: false
      add :cancel_operation_id, :string, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:payment_settlement_shares, [:payment_operation_id])
    create index(:payment_settlement_shares, [:cancel_operation_id])
    create index(:payment_settlement_shares, [:settling_group_id])
  end
end
