defmodule GroupStay.Credits.CreditLot do
  @moduledoc """
  A dated hotel-credit obligation created by a refundable cancellation.

  `remaining_cents` is the portion currently available. Credit funding an active
  group lives in allocations instead, which pauses this lot's expiry.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :allocations, GroupStay.Credits.CreditAllocation

    timestamps(type: :utc_datetime)
  end

  def creation_changeset(lot, attrs) do
    lot
    |> cast(attrs, [:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_number(:remaining_cents, greater_than: 0)
  end
end
