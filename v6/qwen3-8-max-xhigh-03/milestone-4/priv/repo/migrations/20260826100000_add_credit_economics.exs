defmodule GroupStay.Repo.Migrations.AddCreditEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :credit_paid_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :issued_cents, :integer, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id])
    create index(:credit_lots, [:guest_id, :expires_on])

    create table(:credit_applications) do
      add :group_id,
          references(:groups, type: :string, column: :group_id, on_delete: :delete_all),
          null: false

      add :lot_id,
          references(:credit_lots, column: :id, on_delete: :delete_all),
          null: false

      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:lot_id])
  end
end
