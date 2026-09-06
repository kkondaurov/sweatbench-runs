defmodule GroupStay.Groups.CashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :source_operation_id, :string
    field :amount_cents, :integer
    field :status, :string
    field :fill_seq, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_id,
      :room_id,
      :source_operation_id,
      :amount_cents,
      :status,
      :fill_seq
    ])
    |> validate_required([:group_id, :room_id, :amount_cents, :status, :fill_seq])
  end
end
