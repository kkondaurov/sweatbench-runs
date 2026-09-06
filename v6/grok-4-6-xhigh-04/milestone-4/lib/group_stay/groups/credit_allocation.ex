defmodule GroupStay.Groups.CreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :apply_operation_id, :string
    field :lot_source_operation_id, :string
    field :amount_cents, :integer
    field :fill_seq, :integer
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_id,
      :room_id,
      :apply_operation_id,
      :lot_source_operation_id,
      :amount_cents,
      :fill_seq
    ])
    |> validate_required([
      :group_id,
      :room_id,
      :lot_source_operation_id,
      :amount_cents,
      :fill_seq
    ])
  end
end
