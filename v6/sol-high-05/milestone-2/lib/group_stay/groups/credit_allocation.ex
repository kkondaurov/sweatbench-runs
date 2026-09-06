defmodule GroupStay.Groups.CreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_allocations" do
    field :amount_cents, :integer
    belongs_to :credit_lot, GroupStay.Groups.CreditLot
    belongs_to :group, GroupStay.Groups.Group, references: :group_id, type: :string

    timestamps(type: :utc_datetime)
  end

  @fields ~w(credit_lot_id group_id amount_cents)a

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:credit_lot_id)
    |> foreign_key_constraint(:group_id)
  end
end
