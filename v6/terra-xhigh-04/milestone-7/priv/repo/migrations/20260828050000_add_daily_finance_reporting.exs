defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_settings) do
      add :singleton, :integer, null: false
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_settings, [:singleton])

    create table(:finance_cash_opening_positions) do
      add :property_id, :string, null: false
      add :held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_cash_opening_positions, [:property_id])

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_on, :kind])
    create index(:finance_movements, [:property_id, :posting_on])

    # A lot keeps its normal expiry date for credit use. This table records the date on which
    # that expiry belongs in finance reporting, including a backdated issuance first reported
    # on the reporting inception date.
    create table(:finance_credit_expiries) do
      add :hotel_credit_lot_id, references(:hotel_credit_lots, on_delete: :delete_all),
        null: false

      add :reporting_expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_credit_expiries, [:hotel_credit_lot_id])
    create index(:finance_credit_expiries, [:reporting_expires_on])
  end
end
