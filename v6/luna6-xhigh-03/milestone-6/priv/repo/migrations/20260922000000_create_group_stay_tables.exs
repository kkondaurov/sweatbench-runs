defmodule GroupStay.Repo.Migrations.CreateGroupStayTables do
  use Ecto.Migration

  def change do
    create table(:groups, primary_key: false) do
      add :group_id, :text, primary_key: true
      add :guest_id, :text, null: false
      add :property_id, :text, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :rate_plan, :text, null: false
      add :status, :text, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :revision, :integer, null: false, default: 1
    end

    create table(:group_rooms) do
      add :group_id, references(:groups, column: :group_id, type: :text, on_delete: :delete_all),
        null: false

      add :room_id, :text, null: false
      add :nightly_rate_cents, :integer, null: false
      add :position, :integer, null: false
    end

    create unique_index(:group_rooms, [:group_id, :room_id])
    create unique_index(:group_rooms, [:group_id, :position])

    create table(:ledger_entries) do
      add :group_id, references(:groups, column: :group_id, type: :text, on_delete: :delete_all),
        null: false

      add :entry_type, :text, null: false
      add :amount_cents, :integer, null: false
      add :occurred_on, :date, null: false
    end

    create index(:ledger_entries, [:group_id])
    create index(:ledger_entries, [:entry_type])
  end
end
