defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting) do
      add :latest_closed_on, :date
    end

    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end

    create table(:finance_daily_reports, primary_key: false) do
      add :date, :date, primary_key: true
      add :data, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    execute("""
    INSERT INTO finance_movements (
      operation_id, posting_on, expired_cents, late_adjustment, inserted_at, updated_at
    )
    SELECT
      'credit-expiration-migration', expires_on, amount_cents, 0,
      CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM finance_credit_expirations
    WHERE amount_cents != 0
    """)
  end

  def down do
    drop table(:finance_daily_reports)

    execute("""
    DELETE FROM finance_movements
    WHERE operation_id = 'credit-expiration-migration'
       OR operation_id LIKE 'credit-expiration:%'
    """)

    alter table(:finance_movements) do
      remove :late_adjustment
    end

    alter table(:finance_reporting) do
      remove :latest_closed_on
    end
  end
end
