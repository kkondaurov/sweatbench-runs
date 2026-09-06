defmodule GroupStay.Repo.Migrations.RoomAccountingAndPaymentReductions do
  use Ecto.Migration

  alias GroupStay.Finance.Backfill

  def up do
    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
    end

    alter table(:cash_movements) do
      add :operation_id, :string
    end

    create index(:cash_movements, [:operation_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id), null: false
      add :room_id, references(:group_rooms, type: :binary_id), null: false
      add :funding_type, :string, null: false
      add :source_operation_id, :string
      add :credit_lot_id, references(:credit_lots, type: :binary_id)
      add :amount_cents, :integer, null: false
      add :fill_order, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:source_operation_id])

    create table(:credit_lot_contributions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :credit_lot_id, references(:credit_lots, type: :binary_id), null: false
      add :payment_operation_id, :string
      add :entitled_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lot_contributions, [:credit_lot_id])
    create index(:credit_lot_contributions, [:payment_operation_id])

    flush()

    # Bring pre-release funding forward as room allocations. This only adds the
    # new bookkeeping; no aggregate cash, credit, or liability balance changes.
    Backfill.backfill()

    drop table(:credit_applications)
  end

  def down do
    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id), null: false
      add :credit_lot_id, references(:credit_lots, type: :binary_id), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:credit_lot_id])

    drop table(:credit_lot_contributions)
    drop table(:room_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:cash_movements) do
      remove :operation_id
    end

    alter table(:group_rooms) do
      remove :status
    end
  end
end
