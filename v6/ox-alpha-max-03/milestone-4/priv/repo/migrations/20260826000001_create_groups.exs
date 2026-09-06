defmodule GroupStay.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    create table(:groups, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :group_id, :text, null: false
      add :guest_id, :text, null: false
      add :property_id, :text, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :rate_plan, :text, null: false
      add :status, :text, null: false, default: "active"
      add :revision, :integer, null: false, default: 1
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:group_id])

    create table(:group_rooms, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :group_id, references(:groups, type: :uuid, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :room_id, :text, null: false
      add :nightly_rate_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_rooms, [:group_id])

    create table(:ledger_entries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :group_id, references(:groups, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      add :amount_cents, :integer, null: false
      add :occurred_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:ledger_entries, [:group_id])
    create index(:ledger_entries, [:kind])
  end
end
