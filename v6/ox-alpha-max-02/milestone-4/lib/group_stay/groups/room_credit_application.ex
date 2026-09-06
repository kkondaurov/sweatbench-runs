defmodule GroupStay.Groups.RoomCreditApplication do
  @moduledoc """
  The portion of a credit lot currently applied to one active room's deposit.

  It preserves which lot funds which room so amounts can be restored when
  their rooms settle refundably. Rows are removed as their rooms settle.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "room_credit_applications" do
    field :applied_cents, :integer, default: 0

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime)
  end
end
