defmodule GroupStay.Reservations.RoomFunding do
  @moduledoc """
  One held funding slice on a room. Insertion order records fill order, including
  later funding of holes reopened by corrections. Cash identifies its payment;
  credit identifies its original lot. Legacy cash has neither identifier.
  Settlements remove slices after recording their permanent disposition.
  """
  use Ecto.Schema

  schema "room_fundings" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer
  end
end
