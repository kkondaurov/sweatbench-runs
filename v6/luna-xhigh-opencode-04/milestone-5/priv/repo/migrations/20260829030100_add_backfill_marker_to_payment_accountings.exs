defmodule GroupStay.Repo.Migrations.AddBackfillMarkerToPaymentAccountings do
  use Ecto.Migration

  def change do
    alter table(:payment_accountings) do
      add :backfilled, :boolean, null: false, default: false
    end
  end
end
