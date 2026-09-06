defmodule GroupStay.Repo.Migrations.CreateRoomAccounting do
  use Ecto.Migration

  def up do
    create table(:room_accounts, primary_key: false) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          primary_key: true

      add :data, :map, null: false
    end

    create table(:lot_clawbacks, primary_key: false) do
      add :lot_id, references(:credit_lots, on_delete: :delete_all), primary_key: true
      add :amount, :integer, null: false
    end

    flush()
    GroupStay.Accounting.backfill(repo())
  end

  def down do
    drop table(:lot_clawbacks)
    drop table(:room_accounts)
  end
end
