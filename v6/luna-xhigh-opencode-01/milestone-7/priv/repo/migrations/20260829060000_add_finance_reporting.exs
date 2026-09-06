defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
    end

    create table(:finance_opening_cash, primary_key: false) do
      add :property_id, :string, primary_key: true
      add :held_cents, :integer, null: false
    end

    create table(:finance_opening_credit, primary_key: false) do
      add :credit_lot_id, :integer, primary_key: true
      add :available_cents, :integer, null: false
      add :liability_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create table(:finance_events) do
      add :operation_id, :string
      add :posting_on, :date, null: false
      add :property_id, :string
      add :credit_lot_id, :integer
      add :credit_available_delta, :integer, null: false, default: 0
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
    end

    create index(:finance_events, [:posting_on])
    create index(:finance_events, [:credit_lot_id, :posting_on])
  end
end
