defmodule GroupStay.Reservations.CreditAllocation do
  @moduledoc """
  A portion of an original credit lot currently funding an active group.

  Keeping this link is what lets refundable cancellation restore credit to its
  original source and expiration date without granting a second bonus.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.{CreditLot, Group, Room}

  schema "credit_allocations" do
    belongs_to :credit_lot, CreditLot

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :room, Room

    field :amount_cents, :integer
    field :funding_operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attributes) do
    allocation
    |> cast(attributes, [
      :credit_lot_id,
      :group_id,
      :room_id,
      :funding_operation_id,
      :amount_cents
    ])
    |> validate_required([:credit_lot_id, :group_id, :room_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
