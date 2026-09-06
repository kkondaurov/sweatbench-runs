defmodule GroupStay.Repo.Migrations.DailyFinanceReport do
  use Ecto.Migration

  @moduledoc """
  Product request 06: the daily finance report.

  One `finance_reporting` row marks the durable reporting inception point:
  the date reporting started and the opening position snapshot taken
  immediately before the first applied start operation was processed.

  `finance_events` is the append-only reporting log. Every operation
  processed after reporting started posts the finance effects it caused,
  each with the posting date — the later of the operation's `occurred_on`
  and `starts_on`. Events commit in the same transaction as the domain
  changes they describe, so rejected operations leave no event and a
  durable retry never posts twice. Credit expiry needs no event: the
  report derives it from the lots' current balances at read time.
  """

  def up do
    create table(:finance_events) do
      add :posting_date, :date, null: false
      # "cash" or "credit".
      add :kind, :string, null: false
      # The movement classification, e.g. "received" or "expired".
      add :classification, :string, null: false
      # The property whose held cash moved; nil for company-wide credit.
      add :property_id, :string
      # Signed net amount within the classification.
      add :amount_cents, :integer, null: false
      # The partner operation that caused the event.
      add :source_operation_id, :string
      # Optional identity of the affected domain row, e.g. a lot id.
      add :source_id, :string

      timestamps()
    end

    create index(:finance_events, [:posting_date])
    create index(:finance_events, [:kind, :classification])

    create table(:finance_reporting) do
      # Only one row may ever exist.
      add :singleton, :boolean, null: false, default: true
      add :starts_on, :date, null: false
      add :operation_id, :string, null: false
      # The opening position snapshot as canonical JSON.
      add :opening_position, :text, null: false

      timestamps()
    end

    create unique_index(:finance_reporting, [:singleton])
  end

  def down do
    drop table(:finance_reporting)
    drop table(:finance_events)
  end
end
