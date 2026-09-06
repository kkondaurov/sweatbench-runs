defmodule GroupStay.Repo.Migrations.CreateOperationalCore do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :group_id, :string, null: false
      add :guest_id, :string, null: false
      add :property_id, :string, null: false
      add :revision, :integer, null: false, default: 1
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :rate_plan, :string, null: false
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:group_id])

    create table(:group_rooms) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, :string, null: false
      add :nightly_rate_cents, :integer, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_rooms, [:group_id])
    create unique_index(:group_rooms, [:group_id, :room_id])

    create table(:ledger_entries) do
      add :group_id, references(:groups, on_delete: :nothing), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :occurred_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:ledger_entries, [:group_id])
  end
end
