defmodule GroupStay.Repo.Migrations.CreateReservations do
  use Ecto.Migration

  def change do
    create table(:groups, primary_key: false) do
      add :group_id, :text, primary_key: true, null: false
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
      add :cash_refunded_cents, :integer, null: false, default: 0

      add :cash_retained_cents, :integer,
        null: false,
        default: 0,
        check: %{
          name: "valid_group_balances",
          expr:
            "lodging_total_cents >= 0 AND deposit_due_cents >= 0 AND " <>
              "deposit_paid_cents >= 0 AND deposit_paid_cents <= deposit_due_cents AND " <>
              "cash_refunded_cents >= 0 AND cash_retained_cents >= 0 AND revision > 0"
        }
    end

    create table(:rooms) do
      add :group_id, references(:groups, column: :group_id, type: :text, on_delete: :delete_all),
        null: false

      add :room_id, :text, null: false
      add :position, :integer, null: false

      add :nightly_rate_cents, :integer,
        null: false,
        check: %{
          name: "valid_room_amount_and_position",
          expr: "nightly_rate_cents >= 0 AND position >= 0"
        }
    end

    create unique_index(:rooms, [:group_id, :room_id])
    create unique_index(:rooms, [:group_id, :position])
  end
end
