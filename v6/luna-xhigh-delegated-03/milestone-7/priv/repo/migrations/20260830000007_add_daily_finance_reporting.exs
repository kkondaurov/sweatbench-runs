defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0
    end

    create table(:finance_reporting_openings) do
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_reporting_openings, [:property_id])

    create table(:finance_reporting_credit_openings) do
      add :credit_lot_id, :integer, null: false
      add :available_cents, :integer, null: false, default: 0
      add :applied_cents, :integer, null: false, default: 0
      add :expires_on, :date, null: false
    end

    create unique_index(:finance_reporting_credit_openings, [:credit_lot_id])

    create table(:finance_postings) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :property_id, :string
      add :payment_operation_id, :string
      add :credit_lot_id, :integer

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

      add :credit_available_delta_cents, :integer, null: false, default: 0
      add :credit_applied_delta_cents, :integer, null: false, default: 0
    end

    create index(:finance_postings, [:posting_on])
    create index(:finance_postings, [:payment_operation_id])
    create index(:finance_postings, [:credit_lot_id, :posting_on])
  end
end
