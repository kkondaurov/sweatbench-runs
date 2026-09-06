defmodule GroupStay.Finance.CreditApplication do
  @moduledoc """
  Hotel credit from a lot currently funding a group's deposit.

  While the group is active the applied amount keeps its value regardless of
  the source lot's expiry. It returns to the lot on a refundable cancellation
  and is consumed on a non-refundable one.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Bookings.Group
    belongs_to :credit_lot, GroupStay.Finance.CreditLot

    timestamps(type: :utc_datetime)
  end
end
