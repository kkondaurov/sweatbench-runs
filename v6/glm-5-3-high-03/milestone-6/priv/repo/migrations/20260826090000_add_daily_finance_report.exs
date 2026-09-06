defmodule GroupStay.Repo.Migrations.AddDailyFinanceReport do
  use Ecto.Migration

  def change do
    # The durable inception point of finance reporting: a single row, created
    # when the first start_finance_reporting operation is applied. It fixes
    # the reporting start date and the opening credit liability observed just
    # before that operation was processed.
    create table(:finance_reporting_states, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :operation_id, :string, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # The opening held-cash position per property, observed when reporting
    # started.
    create table(:finance_openings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reporting_state_id,
          references(:finance_reporting_states, type: :integer, on_delete: :delete_all),
          null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:finance_openings, [:reporting_state_id])

    # One reported movement of held cash or hotel-credit liability: the
    # posting date is the later of the operation's occurred_on and the
    # reporting starts_on date. Cash movements carry the property the cash was
    # held at or settled through; credit movements, the company-wide
    # liability, carry no property.
    create table(:finance_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :posting_date, :date, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_date])
    create index(:finance_movements, [:property_id])

    alter table(:credit_lots) do
      # Entitlement clawed back from a lot that had already expired when
      # reporting had started: its value left the liability through the lot's
      # expiry, so the daily report counts it with that expiry instead of as a
      # revocation.
      add :clawed_back_expired_cents, :integer, null: false, default: 0
    end
  end
end
