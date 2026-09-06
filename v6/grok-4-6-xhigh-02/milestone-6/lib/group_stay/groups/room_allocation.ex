defmodule GroupStay.Groups.RoomAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_allocations" do
    field :kind, :string
    field :amount_cents, :integer
    field :source_operation_id, :string
    field :fill_seq, :integer

    belongs_to :room, GroupStay.Groups.Room
    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :kind,
      :amount_cents,
      :source_operation_id,
      :fill_seq,
      :room_id,
      :credit_lot_id
    ])
    |> validate_required([:kind, :amount_cents, :fill_seq, :room_id])
  end
end
