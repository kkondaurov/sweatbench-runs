defmodule GroupStay.Repo.Migrations.CreateGroupsAndRooms do
  use Ecto.Migration

  def change do
    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, :string, null: false
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
      add :cash_refunded_cents, :integer, null: false, default: 0
      add :cash_retained_cents, :integer, null: false, default: 0
      add :revision, :integer, null: false
    end

    create unique_index(:groups, [:group_id])

    create table(:rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_record_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :room_id, :string, null: false
      add :nightly_rate_cents, :integer, null: false
    end

    create unique_index(:rooms, [:group_record_id, :room_id])
    create unique_index(:rooms, [:group_record_id, :position])
  end
end
