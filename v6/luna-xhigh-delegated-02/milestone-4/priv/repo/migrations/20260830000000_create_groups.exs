defmodule GroupStay.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :group_id, :text, null: false
      add :guest_id, :text, null: false
      add :property_id, :text, null: false
      add :booked_on, :date, null: false
      add :arrival_on, :date, null: false
      add :departure_on, :date, null: false
      add :rate_plan, :text, null: false
      add :rooms_json, :text, null: false
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :cash_refunded_cents, :integer, null: false, default: 0
      add :cash_retained_cents, :integer, null: false, default: 0
      add :status, :text, null: false, default: "active"
      add :revision, :integer, null: false, default: 1
    end

    create unique_index(:groups, [:group_id])
  end
end
