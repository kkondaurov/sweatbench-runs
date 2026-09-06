defmodule GroupStay.Repo.Migrations.CreateGroupStayCore do
  use Ecto.Migration

  def change do
    create table(:groups, primary_key: false) do
      add :group_id, :string, primary_key: true
      add :guest_id, :string, null: false
      add :property_id, :string, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :rate_plan, :string, null: false
      add :status, :string, null: false
      add :revision, :integer, null: false
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false
    end

    create table(:group_rooms) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string, null: false
      add :nightly_rate_cents, :integer, null: false
      add :position, :integer, null: false
    end

    create unique_index(:group_rooms, [:group_id, :room_id])
    create index(:group_rooms, [:group_id, :position])

    create table(:ledger, primary_key: false) do
      add :id, :integer, primary_key: true
      add :cash_held_cents, :integer, null: false, default: 0
      add :cash_refunded_cents, :integer, null: false, default: 0
      add :cash_retained_cents, :integer, null: false, default: 0
    end

    execute "INSERT INTO ledger (id, cash_held_cents, cash_refunded_cents, cash_retained_cents) VALUES (1, 0, 0, 0)",
            "DELETE FROM ledger WHERE id = 1"
  end
end
