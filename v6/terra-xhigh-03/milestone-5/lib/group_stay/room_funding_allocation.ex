defmodule GroupStay.RoomFundingAllocation do
  @moduledoc """
  A room-level unit of funding and its current cash or credit disposition.

  Cash rows retain the original payment operation identifier where one exists. Credit rows retain
  their originating lot so refundable settlements can restore exactly the right entitlement.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "room_funding_allocations" do
    field :funding_type, :string
    field :payment_operation_id, :string
    field :status, :string
    field :amount_cents, :integer
    field :credit_entitlement_cents, :integer, default: 0
    field :has_been_transferred, :boolean, default: false

    belongs_to :group_reservation, GroupStay.GroupReservation
    belongs_to :group_room, GroupStay.GroupRoom
    belongs_to :credit_lot, GroupStay.CreditLot
    belongs_to :credit_application, GroupStay.CreditApplication

    timestamps(type: :utc_datetime)
  end

  def create_changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_reservation_id,
      :group_room_id,
      :credit_lot_id,
      :credit_application_id,
      :funding_type,
      :payment_operation_id,
      :status,
      :amount_cents,
      :credit_entitlement_cents,
      :has_been_transferred
    ])
    |> validate_required([:group_reservation_id, :funding_type, :status, :amount_cents])
  end
end
