defmodule GroupStay.Repo.Migrations.AddOriginalBackfillDispositions do
  use Ecto.Migration

  def change do
    alter table(:payment_accountings) do
      add :backfilled_refunded_cents, :integer, null: false, default: 0
      add :backfilled_retained_cents, :integer, null: false, default: 0
      add :backfilled_converted_to_credit_cents, :integer, null: false, default: 0
    end
  end
end
