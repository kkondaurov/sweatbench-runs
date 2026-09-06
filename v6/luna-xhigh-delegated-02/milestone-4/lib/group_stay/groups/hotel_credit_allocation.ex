defmodule GroupStay.Groups.HotelCreditAllocation do
  @moduledoc "Tracks which credit lot funded an active group's deposit."

  use Ecto.Schema
  import Ecto.Changeset

  schema "hotel_credit_allocations" do
    field :group_id, :string
    field :lot_id, :integer
    field :room_id, :string
    field :operation_id, :string
    field :amount_cents, :integer
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_id, :lot_id, :room_id, :operation_id, :amount_cents])
    |> validate_required([:group_id, :lot_id, :amount_cents])
  end
end
