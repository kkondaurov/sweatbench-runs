defmodule GroupStay.Repo.Migrations.CreateGroups do
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
      add :status, :string, null: false
      add :rooms, {:array, :map}, null: false
      add :lodging_total_cents, :integer, null: false
      add :deposit_due_cents, :integer, null: false
      add :deposit_paid_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :revision, :integer, null: false, default: 1
    end
  end
end
