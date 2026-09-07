defmodule GroupStay.Repo.Migrations.CreateReservations do
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
      add :status, :string, null: false, default: "active"
      add :revision, :integer, null: false, default: 1
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create table(:rooms) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string, null: false
      add :position, :integer, null: false
      add :nightly_rate_cents, :integer, null: false
    end

    create unique_index(:rooms, [:group_id, :room_id])
    create unique_index(:rooms, [:group_id, :position])
  end
end
