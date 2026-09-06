defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    # Single-row durable state: when reporting started and the opening
    # credit-liability position snapped at that moment.
    create table(:finance_reportings) do
      add :starts_on, :date, null: false
      add :opening_liability_cents, :integer, null: false

      timestamps()
    end

    # Opening held cash per property, snapped when reporting started.
    create table(:finance_openings) do
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps()
    end

    create unique_index(:finance_openings, [:property_id])

    # The durably committed movement journal. Credit rows (property_id NULL)
    # may carry a lot-level remaining-balance delta used to derive expiry.
    create table(:finance_movements) do
      add :posting_date, :date, null: false
      add :property_id, :string
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :lot_id, :integer
      add :remaining_delta_cents, :integer
      add :operation_id, :string, null: false

      timestamps()
    end

    create index(:finance_movements, [:posting_date])
    create index(:finance_movements, [:property_id, :posting_date])
    create index(:finance_movements, [:lot_id])
  end
end
