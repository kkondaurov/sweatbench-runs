defmodule GroupStay.Finance.Ledger do
  @moduledoc """
  The single ledger row holding finance totals for cash across all reservations.
  """

  use Ecto.Schema

  schema "ledger" do
    field :cash_held_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
