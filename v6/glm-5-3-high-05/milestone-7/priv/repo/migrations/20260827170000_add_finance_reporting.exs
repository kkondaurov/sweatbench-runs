defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    # The durable reporting inception point: one row, written by the first
    # applied `start_finance_reporting` operation. It fixes `starts_on` and
    # the opening credit liability as of that date, evaluated on the state
    # of every operation committed before the start operation processed.
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_liability_cents, :integer, null: false

      timestamps()
    end

    # The posted finance-movement journal. Movements exist only for
    # operations processed after reporting started; each row carries the
    # operation's reporting posting date (the later of its `occurred_on`
    # and `starts_on`). Amounts are signed net amounts within their
    # classification. The integer primary key preserves processing order.
    create table(:finance_events, primary_key: false) do
      add :id, :id, primary_key: true
      add :posting_on, :date, null: false
      add :property_id, :text
      add :kind, :text, null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:finance_events, [:posting_on])
  end
end
