defmodule GroupStay.Repo.Migrations.CreateCreditMovements do
  use Ecto.Migration

  def change do
    # The durable history of how each credit lot's liability moved: an
    # "applied" movement when an operation redeemed a lot into a group's
    # deposit, and a "restored" or "consumed" movement when a settlement gave
    # the credit back to its lot or consumed it. Room-scoped applications are
    # deleted when the rooms they fund settle, so the daily finance report
    # replays liability movements from this record instead.
    create table(:credit_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all), null: false

      add :operation_id, :string, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_movements, [:operation_id])
    create index(:credit_movements, [:lot_id])
  end
end
