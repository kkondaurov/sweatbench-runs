defmodule GroupStay.Groups.FundingAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "funding_allocations" do
    field :funding_type, :string
    field :funding_operation_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
    field :transferred, :boolean, default: false

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_id,
      :room_id,
      :credit_lot_id,
      :funding_type,
      :funding_operation_id,
      :payment_operation_id,
      :amount_cents,
      :disposition,
      :transferred
    ])
    |> validate_required([:group_id, :room_id, :funding_type, :amount_cents, :disposition])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
