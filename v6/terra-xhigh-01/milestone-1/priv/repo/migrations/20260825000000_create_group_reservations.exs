defmodule GroupStay.Repo.Migrations.CreateGroupReservations do
  use Ecto.Migration

  def change do
    create table(:group_reservations) do
      add :partner_group_id, :string, null: false
      add :guest_id, :string, null: false
      add :property_id, :string, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :rate_plan, :string, null: false
      add :status, :string, null: false
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :outstanding_deposit_cents, :integer, null: false
      add :cash_refunded_cents, :integer, null: false, default: 0
      add :cash_retained_cents, :integer, null: false, default: 0
      add :revision, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_reservations, [:partner_group_id])

    create table(:group_rooms) do
      add :group_reservation_id, references(:group_reservations, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :room_id, :string, null: false
      add :nightly_rate_cents, :integer, null: false
    end

    create unique_index(:group_rooms, [:group_reservation_id, :position])
    create unique_index(:group_rooms, [:group_reservation_id, :room_id])
  end
end
