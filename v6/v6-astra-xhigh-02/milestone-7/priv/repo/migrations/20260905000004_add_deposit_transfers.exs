defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:room_allocations) do
      # This follows the funding through later transfers, splits and settlements,
      # so a payment's statement remembers participation after its held cash is gone.
      add :transferred, :boolean, null: false, default: false
    end
  end
end
