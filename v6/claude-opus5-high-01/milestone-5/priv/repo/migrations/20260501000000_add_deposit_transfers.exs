defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  @moduledoc """
  Marks the room allocations a deposit transfer created.

  A payment's statement reports where its held cash sits once any of that cash
  has moved between groups, and it keeps reporting it after the moved cash has
  been settled. The mark therefore lives on the allocation rows, which outlive
  every balance they contributed to, rather than being derived from balances.

  Existing rows predate transfers, so they carry the default.
  """

  use Ecto.Migration

  def change do
    alter table(:room_allocations) do
      add :transferred, :boolean, null: false, default: false
    end
  end
end
