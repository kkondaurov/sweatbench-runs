defmodule GroupStay.Finance.OpeningPosition do
  @moduledoc """
  The financial position captured when finance reporting starts. Cash rows
  carry the held cash per property; the single credit row carries the
  company-wide credit liability. Every daily report begins from these amounts
  on `starts_on`.
  """

  use Ecto.Schema

  schema "finance_opening_positions" do
    field :scope, :string
    field :property_id, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
