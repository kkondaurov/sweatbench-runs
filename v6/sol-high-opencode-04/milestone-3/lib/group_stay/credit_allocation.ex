defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_allocations" do
    belongs_to :credit_lot, GroupStay.CreditLot
    belongs_to :group, GroupStay.Group
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:credit_lot_id, :group_id, :amount_cents])
    |> validate_required([:credit_lot_id, :group_id, :amount_cents])
  end
end
