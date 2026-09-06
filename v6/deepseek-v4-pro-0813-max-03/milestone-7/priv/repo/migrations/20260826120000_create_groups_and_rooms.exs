defmodule GroupStay.Repo.Migrations.CreateGroupsAndRooms do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :group_id, :string, null: false
      add :guest_id, :string, null: false
      add :property_id, :string, null: false
      add :status, :string, null: false
      add :rate_plan, :string, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :revision, :integer, null: false
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false
      add :refunded_cents, :integer, null: false
      add :retained_cents, :integer, null: false

      timestamps()
    end

    create unique_index(:groups, [:group_id])

    create table(:rooms) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, :string, null: false
      add :nightly_rate_cents, :integer, null: false
      add :position, :integer, null: false

      timestamps()
    end
  end
end
