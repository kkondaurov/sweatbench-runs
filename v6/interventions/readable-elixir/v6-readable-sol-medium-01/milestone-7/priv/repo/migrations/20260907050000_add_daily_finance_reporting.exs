defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_settings) do
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create table(:finance_cash_openings) do
      add :reporting_setting_id,
          references(:finance_reporting_settings, on_delete: :delete_all),
          null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false
    end

    create unique_index(:finance_cash_openings, [:reporting_setting_id, :property_id])

    create table(:finance_movements) do
      add :posting_on, :date, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all)
      add :scheduled_expiry, :boolean, null: false, default: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:finance_movements, [:posting_on])
    create index(:finance_movements, [:property_id, :posting_on])

    create unique_index(:finance_movements, [:credit_lot_id],
             where: "scheduled_expiry = 1",
             name: :finance_movements_one_scheduled_expiry_per_lot
           )
  end
end
