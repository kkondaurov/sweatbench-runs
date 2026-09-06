defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    # The durable reporting inception point. Created by the first applied
    # start_finance_reporting operation; it freezes the opening position and
    # records enough per-lot state to derive later natural credit expiries.
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :opening_liability_cents, :integer, null: false, default: 0
      add :opening_cash_held_cents, :map, null: false, default: %{}
      add :lot_snapshot, :map, null: false, default: %{}

      timestamps()
    end

    # One finance movement recorded while reporting is active. Cash rows are
    # attributed to a property; credit rows are company-wide. Internal
    # classifications never appear in reports.
    create table(:finance_events) do
      add :posted_on, :date, null: false
      add :scope, :string, null: false
      add :classification, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:finance_events, [:posted_on])

    # Per-lot funding and balance movements, kept separately so natural
    # expiries can be derived from the reporting history alone.
    create table(:finance_lot_events) do
      add :posted_on, :date, null: false
      add :credit_lot_id, :integer, null: false
      add :remaining_delta_cents, :integer, null: false, default: 0
      add :funded_delta_cents, :integer, null: false, default: 0

      timestamps()
    end

    create index(:finance_lot_events, [:credit_lot_id])
  end
end
