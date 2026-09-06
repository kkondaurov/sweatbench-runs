defmodule GroupStay.Credit.Redemption do
  @moduledoc """
  Credit taken from one lot to fund one group's deposit.

  The row records which lot paid for the group so the amount can be returned to
  that lot, with its original expiry, if the group is later cancelled while it is
  still refundable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credit.Lot
  alias GroupStay.Reservations.Group

  schema "credit_redemptions" do
    field :amount_cents, :integer

    belongs_to :lot, Lot, foreign_key: :lot_ref
    belongs_to :group, Group, foreign_key: :group_ref

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:lot_ref, :group_ref, :amount_cents]

  def changeset(redemption, attrs) do
    redemption
    |> cast(attrs, @fields)
    |> validate_required(@fields)
  end
end
