defmodule GroupStay.Funding.CashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_allocations" do
    field :operation_id, :string
    field :amount_cents, :integer
    field :sequence, :integer
    field :order_lo, :integer
    field :disposition, :string

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    belongs_to :credit_lot, GroupStay.Credits.Lot

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_id,
      :room_id,
      :credit_lot_id,
      :operation_id,
      :amount_cents,
      :sequence,
      :order_lo,
      :disposition
    ])
    |> validate_required([:group_id, :room_id, :amount_cents, :sequence, :disposition])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:disposition, [
      "held",
      "refunded",
      "retained",
      "converted",
      "reduced",
      "charged_back"
    ])
  end
end
