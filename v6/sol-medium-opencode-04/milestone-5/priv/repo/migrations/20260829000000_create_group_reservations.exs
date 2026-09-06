defmodule GroupStay.Repo.Migrations.CreateGroupReservations do
  use Ecto.Migration

  def change do
    create table(:group_reservations) do
      add :group_id, :string, null: false
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
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:group_reservations, [:group_id])

    create table(:group_rooms) do
      add :group_reservation_id, references(:group_reservations, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :room_id, :string, null: false
      add :nightly_rate_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:group_rooms, [:group_reservation_id, :room_id])
    create unique_index(:group_rooms, [:group_reservation_id, :position])
  end
end
