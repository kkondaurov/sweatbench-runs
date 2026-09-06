defmodule GroupStay.Finance.LedgerEntry do
  @moduledoc """
  An accounting fact recorded against a group. Cancellation settlements are
  recorded as `refunded` or `retained` entries.
  """

  use Ecto.Schema

  @kinds ~w(refunded retained)

  schema "ledger_entries" do
    field :group_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
end
