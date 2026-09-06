defmodule GroupStay.Repo.Migrations.CreateFinanceReporting do
  use Ecto.Migration

  def change do
    # The durable reporting inception point. `started_after_durable_id` is
    # the durable record of the start operation itself: journal entries
    # belonging to earlier durable records form the opening position and
    # later ones form dated movements. It is backfilled inside the start
    # operation's own transaction once its durable record is inserted.
    create table(:finance_reporting_states) do
      add :starts_on, :date, null: false
      add :start_operation_id, :string, null: false
      add :started_after_durable_id, :integer
      add :opening_applied_credit_cents, :integer, null: false
      add :singleton, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:finance_reporting_states, [:singleton])

    # The per-property cash held when reporting started.
    create table(:finance_open_cash, primary_key: false) do
      add :property_id, :string, primary_key: true
      add :opening_held_cents, :integer, null: false

      timestamps()
    end

    # Each credit lot's remaining balance when reporting started. Expiry
    # movements are reconstructed from this base plus later lot deltas.
    create table(:finance_open_credit_lots, primary_key: false) do
      add :credit_lot_id, references(:credit_lots, type: :binary_id), primary_key: true
      add :opening_remaining_cents, :integer, null: false

      timestamps()
    end

    # Signed movement entries produced by applied partner operations.
    # Cash-side entries carry a property; credit-side entries leave
    # `property_id` null. `durable_operation_id` is backfilled in the same
    # transaction as the operation's durable record and separates opening
    # contributions from dated movements.
    create table(:finance_journal) do
      add :operation_id, :string, null: false
      add :durable_operation_id, :integer
      add :posting_date, :date, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false
      add :payment_id, references(:payments, type: :binary_id)
      add :credit_lot_id, references(:credit_lots, type: :binary_id)

      timestamps()
    end

    create index(:finance_journal, [:durable_operation_id])
    create index(:finance_journal, [:posting_date])
    create index(:finance_journal, [:payment_id])
    create index(:finance_journal, [:credit_lot_id])

    # Reported changes to a lot's remaining balance (application, normal
    # restoration, issuance, revocation). Expiry is reconstructed from these.
    create table(:finance_lot_deltas) do
      add :credit_lot_id, references(:credit_lots, type: :binary_id), null: false
      add :operation_id, :string, null: false
      add :durable_operation_id, :integer
      add :posting_date, :date, null: false
      add :delta_cents, :integer, null: false

      timestamps()
    end

    create index(:finance_lot_deltas, [:credit_lot_id])
    create index(:finance_lot_deltas, [:durable_operation_id])
  end
end
