defmodule GroupStay.FinanceOpenCash do
  use Ecto.Schema

  @moduledoc """
  The cash held on each property when finance reporting started.
  """

  @primary_key false

  schema "finance_open_cash" do
    field :property_id, :string, primary_key: true
    field :opening_held_cents, :integer

    timestamps()
  end
end
