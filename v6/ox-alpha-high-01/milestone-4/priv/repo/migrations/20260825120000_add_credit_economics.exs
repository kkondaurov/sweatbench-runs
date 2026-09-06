defmodule GroupStay.Repo.Migrations.AddCreditEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups, primary_key: false) do
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_applied_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    # Groups created before credit existed could only be funded with cash.
    execute "UPDATE groups SET cash_paid_cents = deposit_paid_cents"

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :issued_on, :date, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id])

    create table(:group_credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id), null: false
      add :credit_lot_id, references(:credit_lots, type: :binary_id), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_credit_applications, [:group_id])
  end

  def down do
    drop table(:group_credit_applications)
    drop table(:credit_lots)

    alter table(:groups, primary_key: false) do
      remove :cash_paid_cents
      remove :credit_applied_cents
      remove :converted_to_credit_cents
    end
  end
end
