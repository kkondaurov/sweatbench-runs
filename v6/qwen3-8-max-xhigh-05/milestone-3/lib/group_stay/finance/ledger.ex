defmodule GroupStay.Finance.Ledger do
  @moduledoc """
  The single ledger row holding finance totals for cash across all reservations.

  Credit liability is not stored here: it depends on the reporting date, so it
  is computed from the credit lots and applications as of that date.
  """

  use Ecto.Schema

  schema "ledger" do
    field :cash_held_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
