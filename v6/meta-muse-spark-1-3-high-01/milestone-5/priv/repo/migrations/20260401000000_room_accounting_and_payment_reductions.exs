defmodule GroupStay.Repo.Migrations.RoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :lodging_cents, :integer, default: 0
      add :deposit_due_cents, :integer, default: 0
      add :cash_paid_cents, :integer, default: 0
      add :credit_paid_cents, :integer, default: 0
      add :status, :string, default: "active"
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, default: 0
      add :cash_charged_back_cents, :integer, default: 0
      add :room_accounting_seeded, :boolean, default: false
    end

    create table(:room_fundings) do
      add :group_db_id, references(:groups, on_delete: :delete_all), null: false
      add :room_db_id, references(:rooms, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :source_operation_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :nilify_all)
      add :amount_cents, :integer, null: false
      add :seq, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_fundings, [:group_db_id])
    create index(:room_fundings, [:room_db_id])
    create index(:room_fundings, [:source_operation_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, default: 0
    end
  end
end
