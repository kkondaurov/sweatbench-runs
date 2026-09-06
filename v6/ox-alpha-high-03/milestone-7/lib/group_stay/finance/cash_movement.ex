defmodule GroupStay.Finance.CashMovement do
  @moduledoc """
  An accounting fact about cash recorded for a group.

  Cash starts as `held` while the reservation is active and later moves to
  `refunded`, `retained`, or `converted_to_credit` when rooms settle, or to
  `reduced` or `charged_back` through provider corrections.

  `operation_id` identifies the `record_cash_payment` operation that recorded
  the cash. Legacy funding recorded before durable operation records existed
  has `nil`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_movements" do
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date
    field :operation_id, :string

    belongs_to :group, GroupStay.Bookings.Group

    timestamps(type: :utc_datetime)
  end
end
