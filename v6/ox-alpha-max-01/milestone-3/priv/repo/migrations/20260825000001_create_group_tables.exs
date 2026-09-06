defmodule GroupStay.Repo.Migrations.CreateGroupTables do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :group_id, :text, null: false
      add :guest_id, :text
      add :property_id, :text
      add :revision, :integer, null: false, default: 1
      add :status, :text, null: false, default: "active"
      add :rate_plan, :text, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :deposit_due_cents, :integer, null: false

      timestamps()
    end

    create unique_index(:groups, [:group_id])

    create table(:rooms) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :room_id, :text, null: false
      add :nightly_rate_cents, :integer, null: false

      timestamps()
    end

    create index(:rooms, [:group_id, :position])
    create unique_index(:rooms, [:group_id, :room_id])

    create table(:ledger_entries) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:ledger_entries, [:group_id, :kind])
    create index(:ledger_entries, [:kind])
  end
end
