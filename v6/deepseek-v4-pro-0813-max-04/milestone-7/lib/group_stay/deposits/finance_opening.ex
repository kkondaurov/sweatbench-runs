defmodule GroupStay.Deposits.FinanceOpening do
  use Ecto.Schema

  @moduledoc """
  One property's opening held cash, snapped when finance reporting started.
  Only properties with held cash at that moment have a row; a property whose
  opening position is zero participates in reports solely through movements.
  """

  schema "finance_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer

    timestamps()
  end
end
