defmodule GroupStay.Repo.Migrations.CreateOperationalCore do
  use Ecto.Migration

  def change do
    create table(:groups, primary_key: false) do
      add :group_id, :string, primary_key: true
      add :guest_id, :string, null: false
      add :property_id, :string, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false

      add :rate_plan, :string,
        null: false,
        check: %{
          name: "groups_valid_rate_plan",
          expr: "rate_plan IN ('flexible', 'advance_purchase')"
        }

      add :status, :string,
        null: false,
        check: %{name: "groups_valid_status", expr: "status IN ('active', 'cancelled')"}

      add :revision, :integer,
        null: false,
        check: %{name: "groups_positive_revision", expr: "revision > 0"}

      add :lodging_total_cents, :integer,
        null: false,
        check: %{name: "groups_nonnegative_lodging", expr: "lodging_total_cents >= 0"}

      add :deposit_due_cents, :integer,
        null: false,
        check: %{name: "groups_nonnegative_deposit_due", expr: "deposit_due_cents >= 0"}

      add :deposit_paid_cents, :integer,
        null: false,
        default: 0,
        check: %{name: "groups_nonnegative_deposit_paid", expr: "deposit_paid_cents >= 0"}

      add :cash_held_cents, :integer,
        null: false,
        default: 0,
        check: %{name: "groups_nonnegative_cash_held", expr: "cash_held_cents >= 0"}

      add :cash_refunded_cents, :integer,
        null: false,
        default: 0,
        check: %{name: "groups_nonnegative_cash_refunded", expr: "cash_refunded_cents >= 0"}

      add :cash_retained_cents, :integer,
        null: false,
        default: 0,
        check: %{name: "groups_nonnegative_cash_retained", expr: "cash_retained_cents >= 0"}
    end

    create table(:rooms) do
      add :group_id,
          references(:groups,
            column: :group_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :room_id, :string, null: false

      add :nightly_rate_cents, :integer,
        null: false,
        check: %{name: "rooms_nonnegative_nightly_rate", expr: "nightly_rate_cents >= 0"}

      add :position, :integer,
        null: false,
        check: %{name: "rooms_nonnegative_position", expr: "position >= 0"}
    end

    create unique_index(:rooms, [:group_id, :room_id])
    create unique_index(:rooms, [:group_id, :position])
  end
end
