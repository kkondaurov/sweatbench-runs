defmodule GroupStay.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    # SQLite requires CHECK constraints in CREATE TABLE; it cannot add them later.
    execute """
            CREATE TABLE groups (
              group_id TEXT PRIMARY KEY NOT NULL,
              guest_id TEXT NOT NULL,
              property_id TEXT NOT NULL,
              booked_on TEXT NOT NULL,
              arrival_on TEXT NOT NULL,
              departure_on TEXT NOT NULL CHECK (departure_on > arrival_on),
              rate_plan TEXT NOT NULL CHECK (rate_plan IN ('flexible', 'advance_purchase')),
              status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled')),
              revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
              lodging_total_cents INTEGER NOT NULL CHECK (lodging_total_cents >= 0),
              deposit_due_cents INTEGER NOT NULL CHECK (deposit_due_cents >= deposit_paid_cents),
              deposit_paid_cents INTEGER NOT NULL DEFAULT 0 CHECK (deposit_paid_cents >= 0),
              cash_refunded_cents INTEGER NOT NULL DEFAULT 0 CHECK (cash_refunded_cents >= 0),
              cash_retained_cents INTEGER NOT NULL DEFAULT 0 CHECK (cash_retained_cents >= 0)
            )
            """,
            "DROP TABLE groups"

    execute """
            CREATE TABLE rooms (
              id INTEGER PRIMARY KEY,
              group_id TEXT NOT NULL REFERENCES groups(group_id) ON DELETE CASCADE,
              room_id TEXT NOT NULL,
              nightly_rate_cents INTEGER NOT NULL CHECK (nightly_rate_cents >= 0),
              position INTEGER NOT NULL CHECK (position >= 0)
            )
            """,
            "DROP TABLE rooms"

    create unique_index(:rooms, [:group_id, :room_id])
    create unique_index(:rooms, [:group_id, :position])
  end
end
