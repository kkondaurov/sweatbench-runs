defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :singleton, :integer, null: false
      add :starts_on, :date, null: false
      add :opening_held_cents, :map, null: false
      add :opening_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting, [:singleton])

    create table(:finance_movements) do
      add :operation_id, :string
      add :posted_on, :date, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :credit_lot_id, :binary_id
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posted_on])
    create index(:finance_movements, [:credit_lot_id])
  end
end
