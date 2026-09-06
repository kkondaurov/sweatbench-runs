defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string
      add :credit_paid_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
    end

    create table(:credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :initial_cents, :integer, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lots, [:guest_id, :expires_on])

    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_id])

    flush()
    GroupStay.Groups.backfill_policy_versions()
  end

  def down do
    drop index(:credit_applications, [:group_id])
    drop table(:credit_applications)
    drop index(:credit_lots, [:guest_id, :expires_on])
    drop table(:credit_lots)

    alter table(:groups) do
      remove :converted_cents
      remove :credit_paid_cents
      remove :policy_version
    end
  end
end
