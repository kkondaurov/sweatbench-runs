defmodule GroupStay.Credits.Lot do
  @moduledoc """
  A hotel-credit lot issued to a guest by a refundable cancellation that
  chose credit over a cash refund.

  The lot is available through the day before `expires_on` and expires on
  `expires_on`. `remaining_cents` is the balance not currently applied to an
  active group; amounts applied to a group are tracked by credit
  applications so they can be restored to this lot on a refundable
  cancellation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :expires_on, :date
    field :remaining_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:guest_id, :source_operation_id, :expires_on, :remaining_cents])
    |> validate_required([:guest_id, :source_operation_id, :expires_on, :remaining_cents])
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end
end
