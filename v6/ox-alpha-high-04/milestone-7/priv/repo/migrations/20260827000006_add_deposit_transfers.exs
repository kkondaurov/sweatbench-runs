defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    # Marks the allocations that have moved between groups through a
    # transfer. Once any funding of a cash payment has participated in a
    # transfer, that payment's statement gains the `held_by_group` view;
    # payments never transferred keep the earlier statement shape.
    alter table(:deposit_dispositions) do
      add :transferred, :boolean, null: false, default: false
    end
  end
end
