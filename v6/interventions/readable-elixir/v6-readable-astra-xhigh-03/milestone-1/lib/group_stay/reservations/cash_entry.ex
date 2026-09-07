defmodule GroupStay.Reservations.CashEntry do
  @moduledoc """
  An immutable accounting fact reported by a partner operation.

  Payments increase held cash. Refunds and retentions move held cash into its
  final disposition. Unpaid deposit requirements never produce cash entries.
  Operation identifiers are correlation identifiers, not idempotency keys.
  """
  use Ecto.Schema

  schema "cash_entries" do
    field :group_id, :string
    field :operation_id, :string
    field :occurred_on, :date
    field :kind, Ecto.Enum, values: [:payment, :refund, :retention]
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
