defmodule GroupStay.Deposits.CreditAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer

    belongs_to :lot, GroupStay.Deposits.CreditLot,
      foreign_key: :credit_lot_id,
      define_field: false

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
