defmodule GroupStay.Repo.Migrations.DailyFinanceReport do
  use Ecto.Migration

  def change do
    # A single row once reporting starts. The financial state immediately
    # before the start operation is captured here as the opening position:
    # per-property held cash in `finance_opening_balances` and the company-wide
    # credit liability as of `starts_on`.
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_opening_balances) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_opening_balances, [:finance_reporting_id])

    # Movements recorded by applied partner operations once reporting has
    # started. Credit movements join a company-wide bucket; cash movements
    # carry the property whose held cash they affect. Revocation events
    # denormalize their lot's expiry date so reads can decide whether the
    # removal reduced liability (counts as revoked) or happened after the lot
    # expired (adds back into the derived expiry for that lot).
    create table(:finance_events) do
      add :scope, :string, null: false
      add :classification, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false
      add :posting_date, :date, null: false
      add :credit_lot_id, :integer
      add :lot_expires_on, :date

      timestamps(type: :utc_datetime)
    end

    create index(:finance_events, [:posting_date])
    create index(:finance_events, [:scope, :posting_date])
    create index(:finance_events, [:credit_lot_id])
  end
end
