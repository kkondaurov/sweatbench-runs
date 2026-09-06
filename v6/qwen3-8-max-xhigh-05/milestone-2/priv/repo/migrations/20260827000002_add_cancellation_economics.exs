defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    flush()

    execute "UPDATE groups SET cash_paid_cents = deposit_paid_cents"

    alter table(:ledger) do
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id, :expires_on])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:lot_id])
  end

  def down do
    drop table(:credit_applications)
    drop table(:credit_lots)

    alter table(:ledger) do
      remove :cash_converted_to_credit_cents
    end

    alter table(:groups) do
      remove :credit_paid_cents
      remove :cash_paid_cents
    end
  end
end
