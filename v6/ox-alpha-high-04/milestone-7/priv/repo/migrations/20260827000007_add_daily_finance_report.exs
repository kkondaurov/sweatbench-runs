defmodule GroupStay.Repo.Migrations.AddDailyFinanceReport do
  use Ecto.Migration

  def change do
    # The durable reporting inception point. One row exists once the first
    # `start_finance_reporting` operation applies: `starts_on` anchors the
    # daily report calendar and the opening liability is the credit liability
    # as of that date at the moment reporting began. `singleton` is pinned to
    # 1 with a unique index so at most one inception row can ever commit,
    # even when two start operations race.
    create table(:finance_reporting) do
      add :singleton, :integer, null: false
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:finance_reporting, [:singleton])

    # The opening position captured when reporting started: held cash per
    # property and the available balance of every credit lot that was still
    # unexpired on `starts_on` (a zero balance is kept so post-start
    # restorations into an exhausted lot still reach the expiry simulation).
    create table(:finance_opening_cash) do
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:finance_opening_cash, [:property_id])

    create table(:finance_opening_lots) do
      add :lot_id, :integer, null: false
      add :opening_available_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:finance_opening_lots, [:lot_id])

    # The reporting movement journal. Every finance effect of an operation
    # processed after reporting starts is one row: `posting_on` is the
    # operation's reporting posting date, `scope` splits cash (attributed to
    # a property) from company-wide credit, and `kind` is the named
    # classification from the daily report. Internal credit kinds
    # (`applied`, `returned`, `clawback_removed`) carry no report movement
    # column; they exist so the read-time expiry simulation can replay each
    # lot's available balance.
    create table(:finance_movements) do
      add :posting_on, :date, null: false
      add :scope, :string, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :lot_id, :integer
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:finance_movements, [:posting_on])
    create index(:finance_movements, [:scope, :kind])
    create index(:finance_movements, [:lot_id])
  end
end
