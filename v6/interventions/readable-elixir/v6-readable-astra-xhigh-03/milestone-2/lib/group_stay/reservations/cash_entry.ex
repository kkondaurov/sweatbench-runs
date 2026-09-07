defmodule GroupStay.Reservations.CashEntry do
  @moduledoc """
  An immutable accounting fact reported by a partner operation.

  Payments increase held cash. Refunds and retentions move held cash into its
  final disposition. Credit conversions move cash into credit backing without
  counting it as a refund or retention. Unpaid requirements produce no entries.
  Operation identifiers are correlation identifiers, not idempotency keys.
  """
  use Ecto.Schema

  schema "cash_entries" do
    field :group_id, :string
    field :operation_id, :string
    field :occurred_on, :date
    field :kind, Ecto.Enum, values: [:payment, :refund, :retention, :credit_conversion]
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
