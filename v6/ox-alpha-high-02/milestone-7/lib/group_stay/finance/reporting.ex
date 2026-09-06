defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  The durable reporting inception point created by the first applied
  start_finance_reporting operation.

  The opening position is frozen here at inception: held cash per property,
  the hotel credit liability evaluated as of `starts_on`, and the remaining
  and funded balance of every existing credit lot so later natural expiries
  can be derived without reading live domain state.
  """

  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_liability_cents, :integer, default: 0
    field :opening_cash_held_cents, :map, default: %{}
    # %{"<lot id>"" => %{"remaining_cents" => int, "funded_cents" => int,
    #   "expires_on" => "YYYY-MM-DD"}}
    field :lot_snapshot, :map, default: %{}

    timestamps()
  end
end
