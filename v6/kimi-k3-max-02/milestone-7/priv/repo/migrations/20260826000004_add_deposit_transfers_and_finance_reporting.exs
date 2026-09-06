defmodule GroupStay.Repo.Migrations.AddDepositTransfersAndFinanceReporting do
  use Ecto.Migration

  def change do
    # A cash payment whose funding has participated in a deposit transfer
    # reports held_by_group on its payment statement.
    alter table(:cash_fundings) do
      add :transferred, :boolean, null: false, default: false
    end

    # The durable reporting inception point: the financial state immediately
    # before the first applied start_finance_reporting operation becomes the
    # opening position on starts_on. movements_after_id is the commit-order
    # watermark: funding movements recorded up to it belong to the opening
    # position, later ones are report movements. The singleton sentinel makes
    # the inception point a single row even under concurrent first starts.
    create table(:reporting_states) do
      add :singleton, :string, null: false, default: "only"
      add :starts_on, :date, null: false
      add :movements_after_id, :integer, null: false, default: 0
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:reporting_states, [:singleton])

    # Opening position snapshots taken by the first start_finance_reporting
    # operation: held cash per property, and per-lot remaining credit (with
    # its expiry) so a later report can derive expiries that need no partner
    # operation.
    create table(:reporting_cash_openings) do
      add :reporting_state_id, references(:reporting_states, on_delete: :delete_all), null: false
      add :property_id, :string, null: false
      add :held_cents, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create table(:reporting_lot_openings) do
      add :reporting_state_id, references(:reporting_states, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # One funding movement produced by an applied partner operation. The
    # daily report derives its per-property cash and company-wide credit
    # movements from these rows; posting_on is the later of the operation's
    # occurred_on and the reporting start date, so an operation submitted
    # late still changes the correct open report. Rejected operations record
    # nothing; a durable retry reuses the stored rows instead of reporting
    # the movement twice.
    create table(:funding_movements) do
      add :operation_id, :string
      add :occurred_on, :date, null: false
      add :posting_on, :date, null: false
      add :side, :string, null: false
      add :classification, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false
      add :detail, :map

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:funding_movements, [:posting_on])
    create index(:funding_movements, [:operation_id])
  end
end
