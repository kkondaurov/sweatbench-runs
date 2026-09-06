defmodule GroupStay.Repo.Migrations.CreateGroupsRoomsAndLedger do
  use Ecto.Migration

  def up do
    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, :string, null: false
      add :guest_id, :string, null: false
      add :property_id, :string, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :rate_plan, :string, null: false
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :revision, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:group_id])

    create table(:rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_id, :string, null: false
      add :nightly_rate_cents, :integer, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rooms, [:group_id])
    create unique_index(:rooms, [:group_id, :room_id])

    create table(:ledger) do
      add :cash_held_cents, :integer, null: false, default: 0
      add :cash_refunded_cents, :integer, null: false, default: 0
      add :cash_retained_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    flush()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    repo().insert_all("ledger", [
      %{
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  def down do
    drop table(:ledger)
    drop table(:rooms)
    drop table(:groups)
  end
end
