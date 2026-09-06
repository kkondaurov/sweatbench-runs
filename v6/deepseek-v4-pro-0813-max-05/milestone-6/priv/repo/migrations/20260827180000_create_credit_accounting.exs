defmodule GroupStay.Repo.Migrations.CreateCreditAccounting do
  use Ecto.Migration

  def change do
    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :expires_on, :date, null: false
      add :remaining_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lot_id, references(:credit_lots, type: :binary_id), null: false
      add :group_id, references(:groups, type: :binary_id), null: false
      add :amount_cents, :integer, null: false
      add :status, :string, null: false, default: "applied"

      timestamps()
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:lot_id])
  end
end
