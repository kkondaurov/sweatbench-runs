defmodule GroupStay.Groups.CreditAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_allocations" do
    belongs_to :group, GroupStay.Groups.Group
    belongs_to :credit_lot, GroupStay.Groups.CreditLot
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
