defmodule GroupStay.Credit.Lot do
  @moduledoc """
  A lot of hotel credit issued to a guest, for example when a refundable
  cancellation is settled as hotel credit instead of a cash refund.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    # Entitlement clawed back by a chargeback that could not be removed from
    # the lot's remaining balance.
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :expires_on,
      :unrecovered_clawback_cents
    ])
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end
end
