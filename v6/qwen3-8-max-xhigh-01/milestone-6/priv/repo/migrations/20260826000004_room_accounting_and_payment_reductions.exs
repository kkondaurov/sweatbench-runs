defmodule GroupStay.Repo.Migrations.RoomAccountingAndPaymentReductions do
  use Ecto.Migration

  alias GroupStay.Migrations.Request04

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:cash_payments) do
      add :operation_id, :string
    end

    alter table(:credit_applications) do
      add :operation_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
      add :group_id, references(:groups, type: :binary_id)
    end

    create table(:cash_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :cash_payment_id, references(:cash_payments, type: :binary_id)
      add :amount_cents, :integer, null: false
      add :state, :string, null: false, default: "held"
      add :seq, :integer, null: false
      add :credit_lot_id, references(:credit_lots, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:cash_payment_id])
    create index(:cash_allocations, [:credit_lot_id])

    create table(:credit_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :credit_application_id, references(:credit_applications, type: :binary_id)
      add :lot_id, references(:credit_lots, type: :binary_id), null: false
      add :amount_cents, :integer, null: false
      add :state, :string, null: false, default: "held"
      add :seq, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_allocations, [:room_id])
    create index(:credit_allocations, [:lot_id])
    create index(:credit_allocations, [:credit_application_id])

    create index(:cash_payments, [:operation_id])
    create index(:credit_applications, [:operation_id])
    create index(:credit_lots, [:group_id])

    flush()

    Request04.run()
  end

  def down do
    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end

    drop table(:cash_allocations)
    drop table(:credit_allocations)

    alter table(:rooms) do
      remove :status
      remove :deposit_due_cents
    end

    alter table(:cash_payments) do
      remove :operation_id
    end

    alter table(:credit_applications) do
      remove :operation_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
      remove :group_id
    end
  end
end
