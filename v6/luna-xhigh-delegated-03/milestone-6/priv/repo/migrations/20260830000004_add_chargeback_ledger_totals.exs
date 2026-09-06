defmodule GroupStay.Repo.Migrations.AddChargebackLedgerTotals do
  use Ecto.Migration

  def change do
    alter table(:ledger) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end
  end
end
