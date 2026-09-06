defmodule GroupStay.CreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_allocations" do
    belongs_to :lot, GroupStay.CreditLot
    belongs_to :group, GroupStay.Group, foreign_key: :group_ref
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:lot_id, :group_ref, :amount_cents])
    |> validate_required([:lot_id, :group_ref, :amount_cents])
    |> unique_constraint([:lot_id, :group_ref])
  end
end
