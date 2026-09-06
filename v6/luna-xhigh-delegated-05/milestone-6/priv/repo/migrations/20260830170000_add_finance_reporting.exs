defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_json, :text, null: false
    end

    create table(:finance_report_events) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :event_json, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:finance_report_events, [:operation_id])
    create index(:finance_report_events, [:posting_on])

    create table(:cash_payment_dispositions) do
      add :payment_operation_id, :string, null: false
      add :property_id, :string, null: false
      add :category, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cash_payment_dispositions, [
             :payment_operation_id,
             :property_id,
             :category
           ])

    execute """
            INSERT INTO cash_payment_dispositions
              (payment_operation_id, property_id, category, amount_cents, inserted_at, updated_at)
            SELECT payment_operation_id, property_id, 'refunded', refunded_cents, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            FROM cash_payment_states
            JOIN groups ON groups.id = cash_payment_states.group_id
            WHERE refunded_cents > 0
            UNION ALL
            SELECT payment_operation_id, property_id, 'retained', retained_cents, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            FROM cash_payment_states
            JOIN groups ON groups.id = cash_payment_states.group_id
            WHERE retained_cents > 0
            UNION ALL
            SELECT payment_operation_id, property_id, 'converted_to_credit', converted_to_credit_cents, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            FROM cash_payment_states
            JOIN groups ON groups.id = cash_payment_states.group_id
            WHERE converted_to_credit_cents > 0
            """,
            "DELETE FROM cash_payment_dispositions"
  end
end
