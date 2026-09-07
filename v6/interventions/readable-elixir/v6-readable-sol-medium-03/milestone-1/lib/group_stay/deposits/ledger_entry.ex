defmodule GroupStay.Deposits.LedgerEntry do
  @moduledoc """
  An immutable accounting fact reported by a partner operation.

  Cash payments increase held cash. Cancellation adds either a refund or retention entry, which
  removes that cash from held totals without losing its history.
  """

  use Ecto.Schema

  alias GroupStay.Deposits.Group

  schema "ledger_entries" do
    field :operation_id, :string
    field :occurred_on, :date
    field :kind, :string
    field :amount_cents, :integer

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end
end
