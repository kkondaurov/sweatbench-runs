defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    # Groups created by earlier releases were funded with cash only; derive
    # their cash total from the deposit totals that release recorded.
    execute("UPDATE groups SET cash_paid_cents = deposit_paid_cents")

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :issued_on, :date, null: false
      add :expires_on, :date, null: false
      add :remaining_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_lots, [:guest_id])

    create table(:credit_applications) do
      add :group_id, :string, null: false
      add :lot_id, references(:credit_lots), null: false
      add :amount_cents, :integer, null: false
      add :applied_operation_id, :string, null: false
      add :applied_on, :date, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:lot_id])
  end

  def down do
    drop table(:credit_applications)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end
end
