defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :text, null: false, default: "active"
    end

    alter table(:ledger_entries) do
      add :operation_key, :text
      add :payment_entry_id, references(:ledger_entries, type: :binary_id, on_delete: :delete_all)
    end

    alter table(:credit_applications) do
      add :operation_key, :text
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    # Room allocations track how cash payments and hotel-credit applications
    # fill each active room's deposit. The integer primary key preserves the
    # order in which allocations were created, which is the fill order used by
    # room accounting.
    create table(:room_allocations, primary_key: false) do
      add :id, :id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      add :amount_cents, :integer, null: false
      add :remaining_cents, :integer, null: false, default: 0
      add :settled_cents, :integer, null: false, default: 0
      add :payment_entry_id, references(:ledger_entries, type: :binary_id, on_delete: :delete_all)

      add :credit_application_id,
          references(:credit_applications, type: :binary_id, on_delete: :delete_all)

      timestamps()
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:payment_entry_id])
    create index(:room_allocations, [:credit_application_id])

    # One row per contribution of a cash payment (or the unattributed senior
    # block, when payment_entry_id is null) to a credit lot issued by a
    # cancellation with the hotel-credit refund method.
    create table(:credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all), null: false
      add :payment_entry_id, references(:ledger_entries, type: :binary_id, on_delete: :delete_all)
      add :entitlement_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_entitlements, [:lot_id])
    create index(:credit_entitlements, [:payment_entry_id])
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:credit_applications) do
      remove :operation_key
    end

    alter table(:ledger_entries) do
      remove :payment_entry_id
      remove :operation_key
    end

    alter table(:rooms) do
      remove :status
    end
  end
end
