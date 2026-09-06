defmodule GroupStay.Finance.OpeningCashPosition do
  @moduledoc """
  The held cash for one property at the moment finance reporting started.

  Together with the movements posted after the start, it reconstructs the
  held cash for any reporting date.
  """

  use Ecto.Schema

  alias GroupStay.Finance.ReportingStart

  schema "finance_opening_cash_positions" do
    field :property_id, :string
    field :held_cents, :integer

    belongs_to :reporting_start, ReportingStart

    timestamps()
  end
end
