defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    # A payment whose held cash ever moved through a transfer_deposit
    # operation reports its per-group holdings on its statement.
    alter table(:payment_dispositions) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    # Where the settled portions of one payment's cash were booked. A payment
    # settles under whichever group holds its rooms, so a chargeback has to
    # undo those group-level classifications where they actually happened.
    create table(:payment_settlements) do
      add :payment_operation_id, :string, null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:payment_settlements, [:payment_operation_id, :group_id])
  end
end
