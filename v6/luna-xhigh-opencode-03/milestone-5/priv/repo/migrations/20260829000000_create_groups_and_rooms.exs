defmodule GroupStay.Repo.Migrations.CreateGroupsAndRooms do
  use Ecto.Migration

  def change do
    create table(:groups) do
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
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
    end

    create unique_index(:groups, [:group_id])

    create table(:group_rooms) do
      add :group_record_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, :text, null: false
      add :nightly_rate_cents, :integer, null: false
      add :position, :integer, null: false
    end

    create unique_index(:group_rooms, [:group_record_id, :room_id])
    create index(:group_rooms, [:group_record_id, :position])
  end
end
