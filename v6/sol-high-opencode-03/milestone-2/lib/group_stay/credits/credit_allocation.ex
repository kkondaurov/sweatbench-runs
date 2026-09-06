defmodule GroupStay.Credits.CreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditLot
  alias GroupStay.Reservations.Group

  schema "credit_allocations" do
    field :amount_cents, :integer

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
