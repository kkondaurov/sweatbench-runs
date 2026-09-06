defmodule GroupStay.Credit.Application do
  @moduledoc """
  Records which credit lot funded a room of an active group, and for how
  much, so the credit can be restored to its original lot if the room (or
  group) is later cancelled while refundable.

  Applications recorded before room-level accounting existed carry no room
  or source operation; they are brought forward when the group's funding is
  materialized into room allocations.

  `seq` orders applications globally across cash and credit funding so a
  deposit transfer can draw them in reverse allocation order regardless of
  funding kind; it is null for applications created before deposit transfers
  existed, which order by their attribution instead.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer
    field :source_operation_id, :string
    field :seq, :integer

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    belongs_to :credit_lot, GroupStay.Credit.Lot

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [
      :amount_cents,
      :source_operation_id,
      :seq,
      :group_id,
      :room_id,
      :credit_lot_id
    ])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
