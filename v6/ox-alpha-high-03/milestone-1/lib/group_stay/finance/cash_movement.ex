defmodule GroupStay.Finance.CashMovement do
  @moduledoc """
  An accounting fact about cash held for a group.

  Cash starts as `held` while the reservation is active and becomes either
  `refunded` or `retained` when the reservation is cancelled.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_movements" do
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date

    belongs_to :group, GroupStay.Bookings.Group

    timestamps(type: :utc_datetime)
  end
end
