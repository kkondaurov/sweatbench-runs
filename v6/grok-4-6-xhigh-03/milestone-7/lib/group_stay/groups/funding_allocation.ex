defmodule GroupStay.Groups.FundingAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "funding_allocations" do
    field :source_kind, :string
    field :source_operation_id, :string
    field :funding_kind, :string
    field :amount_cents, :integer
    field :fill_sequence, :integer

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room
    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :source_kind,
      :source_operation_id,
      :funding_kind,
      :amount_cents,
      :fill_sequence,
      :group_id,
      :room_id,
      :credit_lot_id
    ])
    |> validate_required([
      :source_kind,
      :funding_kind,
      :amount_cents,
      :fill_sequence,
      :group_id,
      :room_id
    ])
  end
end
