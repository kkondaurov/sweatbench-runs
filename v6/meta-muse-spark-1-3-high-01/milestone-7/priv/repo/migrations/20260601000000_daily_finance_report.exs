defmodule GroupStay.Repo.Migrations.DailyFinanceReport do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_states) do
      add :starts_on, :date, null: false
      add :started_by_operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_opening_balances) do
      add :state_id, references(:finance_reporting_states, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:finance_opening_balances, [:state_id])

    create table(:finance_cash_movements) do
      add :operation_id, :string, null: false
      add :post_date, :date, null: false
      add :property_id, :string, null: false
      add :received_cents, :integer, null: false, default: 0
      add :transferred_in_cents, :integer, null: false, default: 0
      add :transferred_out_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:finance_cash_movements, [:operation_id], unique: true)
    create index(:finance_cash_movements, [:post_date])

    create table(:finance_credit_movements) do
      add :operation_id, :string, null: false
      add :post_date, :date, null: false
      add :issued_cents, :integer, null: false, default: 0
      add :expired_cents, :integer, null: false, default: 0
      add :consumed_cents, :integer, null: false, default: 0
      add :revoked_cents, :integer, null: false, default: 0
      add :absorbed_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_movements, [:operation_id], unique: true)
    create index(:finance_credit_movements, [:post_date])
  end
end
