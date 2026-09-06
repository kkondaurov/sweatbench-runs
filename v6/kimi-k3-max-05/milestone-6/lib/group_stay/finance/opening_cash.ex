defmodule GroupStay.Finance.OpeningCash do
  @moduledoc """
  One property's held cash in the opening position snapshotted when finance
  reporting started. Only nonzero balances are stored.
  """
  use Ecto.Schema

  schema "finance_opening_cash" do
    field :property_id, :string
    field :opening_held_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
