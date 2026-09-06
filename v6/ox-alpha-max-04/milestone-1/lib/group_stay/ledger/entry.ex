defmodule GroupStay.Ledger.Entry do
  @moduledoc """
  An accounting fact about cash: applying it to a deposit, moving it to a
  refund, or retaining it at cancellation.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ledger_entries" do
    field :type, :string
    field :amount_cents, :integer
    field :occurred_on, :date
    field :operation_id, :string

    belongs_to :group, GroupStay.Groups.Group

    timestamps(type: :utc_datetime)
  end
end
