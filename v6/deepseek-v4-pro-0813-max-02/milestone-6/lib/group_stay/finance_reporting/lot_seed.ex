defmodule GroupStay.FinanceReporting.LotSeed do
  @moduledoc """
  The unapplied balance of one credit lot at the moment finance reporting
  starts. It seeds the lot's lifecycle so expiry movements after the start
  can be attributed to the right report date.
  """

  use Ecto.Schema

  schema "finance_lot_seeds" do
    field :lot_id, :binary_id
    field :initial_cents, :integer, default: 0
  end
end
