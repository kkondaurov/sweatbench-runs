defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_cash_openings) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_cash_openings, [:finance_reporting_id, :property_id])

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :property_id, :string
      add :received_cents, :integer, null: false, default: 0
      add :transferred_in_cents, :integer, null: false, default: 0
      add :transferred_out_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      add :issued_cents, :integer, null: false, default: 0
      add :expired_cents, :integer, null: false, default: 0
      add :consumed_cents, :integer, null: false, default: 0
      add :revoked_cents, :integer, null: false, default: 0
      add :absorbed_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_on])
    create index(:finance_movements, [:property_id, :posting_on])
    create index(:finance_movements, [:operation_id])

    create table(:finance_lot_movements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :posting_on, :date, null: false
      add :available_delta_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_lot_movements, [:credit_lot_id, :posting_on])
  end
end
