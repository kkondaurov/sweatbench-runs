defmodule GroupStay.Repo.Migrations.CreateGroupsAndRooms do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :group_id, :string, null: false
      add :guest_id, :string, null: false
      add :property_id, :string, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :rate_plan, :string, null: false
      add :status, :string, null: false
      add :revision, :integer, null: false, default: 1
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :cash_refunded_cents, :integer, null: false, default: 0
      add :cash_retained_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:groups, [:group_id])

    create table(:rooms) do
      add :group_ref, references(:groups, on_delete: :delete_all), null: false
      add :room_id, :string, null: false
      add :nightly_rate_cents, :integer, null: false
      add :lodging_cents, :integer, null: false
      add :deposit_cents, :integer, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:rooms, [:group_ref])
    create unique_index(:rooms, [:group_ref, :room_id])
  end
end
