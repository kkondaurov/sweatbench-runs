defmodule GroupStay.Reporting.OpeningLot do
  @moduledoc """
  The available balance of one credit lot as of `starts_on`, for every lot
  still unexpired on that date. These balances are the starting point of the
  read-time expiry simulation: a lot's post-start applications, restorations,
  and clawback removals are replayed against its opening balance to find what
  remains unused through `expires_on`.
  """

  use Ecto.Schema

  schema "finance_opening_lots" do
    field :lot_id, :integer
    field :opening_available_cents, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
