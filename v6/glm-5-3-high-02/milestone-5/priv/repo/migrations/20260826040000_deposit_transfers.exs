defmodule GroupStay.Repo.Migrations.DepositTransfers do
  use Ecto.Migration

  @moduledoc """
  Product request 05: deposit transfers between two active groups of the
  same guest.

  A transfer moves held funding by rewriting room allocations, so it needs
  no new table. A payment that has supplied funding to a transfer gains a
  durable mark, because its reconciliation statement must keep reporting
  the groups currently holding its cash even after none remains.
  """

  def up do
    alter table(:payments) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:payments) do
      remove :participated_in_transfer, :boolean
    end
  end
end
