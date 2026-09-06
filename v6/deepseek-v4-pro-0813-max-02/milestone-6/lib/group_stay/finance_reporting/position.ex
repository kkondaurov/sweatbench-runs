defmodule GroupStay.FinanceReporting.Position do
  @moduledoc """
  One property's opening held-cash position, captured when finance reporting
  starts. Properties with zero held cash are not captured.
  """

  use Ecto.Schema

  schema "finance_report_positions" do
    field :property_id, :string
    field :opening_held_cents, :integer, default: 0
  end
end
