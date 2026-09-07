defmodule GroupStay.Credits.CreditAllocation do
  @moduledoc """
  Identifies the original credit lot that funded part of a group deposit.

  Keeping this link is what allows a refundable cancellation to restore credit
  with its original expiry and without granting a second bonus.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditLot
  alias GroupStay.Reservations.{Group, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_allocations" do
    field :amount_cents, :integer
    field :funding_operation_id, :string
    field :funding_order, :integer
    field :allocation_order, :integer
    belongs_to :credit_lot, CreditLot
    belongs_to :group, Group, foreign_key: :group_record_id
    belongs_to :room, Room, foreign_key: :room_record_id

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :credit_lot_id,
      :group_record_id,
      :room_record_id,
      :funding_operation_id,
      :funding_order,
      :allocation_order,
      :amount_cents
    ])
    |> validate_required([
      :credit_lot_id,
      :group_record_id,
      :room_record_id,
      :funding_order,
      :allocation_order,
      :amount_cents
    ])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
