defmodule GroupStay.Groups.GroupCreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :integer

  schema "group_credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents])
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:credit_lot_id)
  end
end
