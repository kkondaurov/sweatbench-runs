defmodule GroupStay.Groups.CreditAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CreditLot, Group}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_allocations" do
    belongs_to :reservation, Group
    belongs_to :credit_lot, CreditLot
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:reservation_id, :credit_lot_id, :amount_cents])
    |> validate_required([:reservation_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
