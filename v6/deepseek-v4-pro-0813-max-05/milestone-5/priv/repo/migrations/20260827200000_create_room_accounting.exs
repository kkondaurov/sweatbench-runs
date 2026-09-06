defmodule GroupStay.Repo.Migrations.CreateRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
    end

    alter table(:payments) do
      # The durable operation that created the payment, or nil for the
      # unattributed senior block brought forward from before durable
      # operation records existed.
      add :operation_id, :string
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:payments, [:operation_id])

    alter table(:credit_applications) do
      add :operation_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :room_id, references(:rooms, type: :binary_id), null: false
      add :group_id, references(:groups, type: :binary_id), null: false
      add :payment_id, references(:payments, type: :binary_id)
      add :credit_application_id, references(:credit_applications, type: :binary_id)
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :status, :string, null: false, default: "held"

      timestamps()
    end

    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:payment_id])
    create index(:room_allocations, [:credit_application_id])

    create table(:credit_lot_contributions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all), null: false
      add :payment_id, references(:payments, type: :binary_id)
      add :settled_cash_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_lot_contributions, [:lot_id])
    create index(:credit_lot_contributions, [:payment_id])

    # One marker per group recording that pre-durable funding has been
    # brought forward into room allocations. Inserting the marker before
    # allocating makes the bring-forward safe under concurrency.
    create table(:legacy_forwardings, primary_key: false) do
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      timestamps()
    end
  end

  def down do
    drop table(:legacy_forwardings)
    drop table(:credit_lot_contributions)
    drop table(:room_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:credit_applications) do
      remove :operation_id
    end

    drop index(:payments, [:operation_id])

    alter table(:payments) do
      remove :operation_id
      remove :refunded_cents
      remove :retained_cents
      remove :converted_cents
      remove :reduced_cents
      remove :charged_back_cents
    end

    alter table(:rooms) do
      remove :status
    end
  end
end
