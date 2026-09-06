defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_starts) do
      add :operation_id, :text, null: false
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0
      add :singleton, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_starts, [:operation_id])
    create unique_index(:finance_reporting_starts, [:singleton])

    create table(:finance_cash_opening_positions) do
      add :finance_reporting_start_id,
          references(:finance_reporting_starts, on_delete: :delete_all), null: false

      add :property_id, :text, null: false
      add :opening_held_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_cash_opening_positions, [
             :finance_reporting_start_id,
             :property_id
           ])

    create table(:finance_cash_movements) do
      add :operation_id, :text, null: false
      add :posting_date, :date, null: false
      add :property_id, :text, null: false
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

    create index(:finance_cash_movements, [:posting_date])
    create index(:finance_cash_movements, [:property_id])
    create index(:finance_cash_movements, [:operation_id])

    create table(:finance_credit_movements) do
      add :operation_id, :text, null: false
      add :posting_date, :date, null: false
      add :issued_cents, :integer, null: false, default: 0
      add :expired_cents, :integer, null: false, default: 0
      add :consumed_cents, :integer, null: false, default: 0
      add :revoked_cents, :integer, null: false, default: 0
      add :absorbed_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_movements, [:posting_date])
    create index(:finance_credit_movements, [:operation_id])
  end
end
