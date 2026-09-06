defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :singleton, :integer, null: false, default: 1
      add :starts_on, :date, null: false
      add :opening_cash, :map, null: false, default: %{}
      add :opening_credit_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting, [:singleton])

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
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
      add :consumed_cents, :integer, null: false, default: 0
      add :revoked_cents, :integer, null: false, default: 0
      add :absorbed_cents, :integer, null: false, default: 0
      add :expired_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_date])
    create index(:finance_movements, [:property_id, :posting_date])
    create unique_index(:finance_movements, [:operation_id, :property_id])

    create table(:finance_credit_expiry_adjustments) do
      add :expires_on, :date, null: false
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_expiry_adjustments, [:expires_on])
  end
end
