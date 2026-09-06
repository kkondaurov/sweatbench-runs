defmodule GroupStay.Finance.CreditApplication do
  @moduledoc """
  A portion of a credit lot currently applied to an active group's deposit.

  The applied amount is redeemed into the group, so it is no longer part of
  the lot's `remaining_cents` and its expiry is paused. Rows are removed when
  their group is cancelled; a refundable cancellation restores each amount to
  its original lot.
  """

  use Ecto.Schema

  schema "credit_applications" do
    field :group_id, :string
    field :lot_id, :integer
    field :amount_cents, :integer
    field :applied_operation_id, :string
    field :applied_on, :date

    timestamps(type: :utc_datetime_usec)
  end
end
