defmodule GroupStay.Finance.PropertyOpening do
  @moduledoc """
  One property's held cash at the reporting opening position.

  Captured once when finance reporting starts; every later cash movement is a
  separate row in `finance_cash_movements`, so a day's opening balance is this
  figure plus the signed movements posted before that day.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_property_openings" do
    field :property_id, :string
    field :cash_held_cents, :integer, default: 0

    timestamps()
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:property_id, :cash_held_cents])
    |> validate_required([:cash_held_cents])
  end
end
