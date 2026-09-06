defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    # A durable marker that this recorded cash payment has had some of its
    # cash moved by a `transfer_deposit` operation. The payment's stored
    # result is never rewritten, so the marker lives in its own column; the
    # reconciliation statement adds `held_by_group` once it is set.
    alter table(:operations) do
      add :involved_in_transfer, :boolean, null: false, default: false
    end
  end
end
