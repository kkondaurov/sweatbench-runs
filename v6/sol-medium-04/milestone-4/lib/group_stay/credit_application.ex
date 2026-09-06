defmodule GroupStay.CreditApplication do
  use Ecto.Schema

  schema "credit_applications" do
    field :amount_cents, :integer
    field :funding_operation_id, :string
    belongs_to :group, GroupStay.Group, type: :string
    belongs_to :credit_lot, GroupStay.CreditLot
    belongs_to :room, GroupStay.Room

    timestamps(type: :utc_datetime)
  end
end
