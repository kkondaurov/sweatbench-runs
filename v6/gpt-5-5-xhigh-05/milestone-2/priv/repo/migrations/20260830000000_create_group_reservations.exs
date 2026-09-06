defmodule GroupStay.Repo.Migrations.CreateGroupReservations do
  use Ecto.Migration

  def change do
    create table(:group_reservations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, :text, null: false
      add :guest_id, :text, null: false
      add :property_id, :text, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :rate_plan, :text, null: false
      add :status, :text, null: false
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :revision, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_reservations, [:group_id])
    create index(:group_reservations, [:status])

    create table(:group_rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_reservation_id,
          references(:group_reservations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :position, :integer, null: false
      add :room_id, :text, null: false
      add :nightly_rate_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_rooms, [:group_reservation_id])
    create unique_index(:group_rooms, [:group_reservation_id, :room_id])
    create unique_index(:group_rooms, [:group_reservation_id, :position])
  end
end
