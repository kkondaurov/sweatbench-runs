defmodule GroupStay.Credit.Lot do
  @moduledoc """
  Hotel credit issued to a guest by one refundable cancellation.

  `remaining_cents` is the part of the lot that is neither redeemed into an active
  group nor already spent. A lot stops being usable on `expires_on`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:guest_id, :source_operation_id, :issued_cents, :remaining_cents, :expires_on]

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end
end
