defmodule GroupStay.Repo.Migrations.AddCreditEconomy do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :credit_paid_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps()
    end

    create table(:credit_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_lots, [:guest_id, :expires_on])
    create index(:credit_allocations, [:group_id])
  end
end
