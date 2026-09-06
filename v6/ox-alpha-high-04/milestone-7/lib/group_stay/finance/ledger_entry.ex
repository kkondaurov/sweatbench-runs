defmodule GroupStay.Finance.LedgerEntry do
  @moduledoc """
  An accounting fact recorded against a group. Cancellation settlements are
  recorded as `refunded`, `retained`, or — when refundable cash is converted
  to hotel credit instead of being refunded — `converted_to_credit` entries.
  Provider corrections add cumulative `reduced` and `charged_back` entries.
  """

  use Ecto.Schema

  @kinds ~w(refunded retained converted_to_credit reduced charged_back)

  schema "ledger_entries" do
    field :group_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
end
