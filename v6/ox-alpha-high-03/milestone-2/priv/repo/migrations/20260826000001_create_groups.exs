defmodule GroupStay.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, :string, null: false
      add :guest_id, :string, null: false
      add :property_id, :string, null: false
      add :status, :string, null: false, default: "active"
      add :rate_plan, :string, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :revision, :integer, null: false, default: 1
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:group_id])

    create table(:group_rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id), null: false
      add :position, :integer, null: false
      add :room_id, :string, null: false
      add :nightly_rate_cents, :integer, null: false
      add :lodging_amount_cents, :integer, null: false
      add :deposit_cents, :integer, null: false
    end

    create index(:group_rooms, [:group_id])
    create unique_index(:group_rooms, [:group_id, :room_id])

    create table(:cash_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :occurred_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_movements, [:group_id])
    create index(:cash_movements, [:kind])
  end
end
