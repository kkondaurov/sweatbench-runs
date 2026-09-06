defmodule GroupStay.Repo.Migrations.AddClosedExpiryAdjustments do
  use Ecto.Migration

  def change do
    alter table(:finance_credit_balance_events) do
      add :expiry_adjustment_cents, :integer, null: false, default: 0
    end
  end
end
