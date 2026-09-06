defmodule GroupStay.Repo.Migrations.BackfillRoomAccounting do
  use Ecto.Migration

  def up do
    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentCorrections) do
      Code.require_file(
        Path.join(__DIR__, "20260830000004_add_room_accounting_and_payment_corrections.exs")
      )
    end

    apply(GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentCorrections, :backfill, [])
  end

  def down, do: :ok
end
