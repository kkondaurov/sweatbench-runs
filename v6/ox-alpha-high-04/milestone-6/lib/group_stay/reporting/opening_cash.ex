defmodule GroupStay.Reporting.OpeningCash do
  @moduledoc """
  The cash held on active reservations per property at the moment reporting
  started: the opening balance the daily report's cash section starts from.
  Later operations never rewrite it — their effects are movements.
  """

  use Ecto.Schema

  schema "finance_opening_cash" do
    field :property_id, :string
    field :opening_held_cents, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
