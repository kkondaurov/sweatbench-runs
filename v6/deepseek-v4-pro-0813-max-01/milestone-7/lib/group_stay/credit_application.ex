defmodule GroupStay.CreditApplication do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer
    field :applied_on, :date
    field :settlement, :string
    field :operation_id, :string

    belongs_to :lot, GroupStay.CreditLot
    belongs_to :group, GroupStay.Group

    has_many :allocations, GroupStay.RoomAllocation

    timestamps()
  end
end
