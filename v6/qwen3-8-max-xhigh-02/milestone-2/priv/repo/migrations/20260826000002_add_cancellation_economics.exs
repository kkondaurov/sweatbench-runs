defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :credit_paid_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
    end

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :original_cents, :integer, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps()
    end

    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_applications) do
      add :lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:lot_id])
  end
end
