defmodule GroupStay.Bookings.CreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Bookings.{CreditLot, Group}

  schema "credit_allocations" do
    field :amount_cents, :integer

    belongs_to :credit_lot, CreditLot
    belongs_to :group, Group, references: :group_id, type: :string
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:credit_lot_id, :group_id, :amount_cents])
    |> validate_required([:credit_lot_id, :group_id, :amount_cents])
  end
end
