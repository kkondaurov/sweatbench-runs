defmodule GroupStay.Groups.RoomFunding do
  use Ecto.Schema

  schema "room_fundings" do
    field :kind, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :funding_order, :integer

    belongs_to :room, GroupStay.Groups.Room

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :credit_lot, GroupStay.Credits.CreditLot

    timestamps(type: :utc_datetime)
  end
end
