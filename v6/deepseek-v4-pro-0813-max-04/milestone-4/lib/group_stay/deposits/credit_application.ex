defmodule GroupStay.Deposits.CreditApplication do
  use Ecto.Schema

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Deposits.Group
    belongs_to :room, GroupStay.Deposits.Room
    belongs_to :credit_lot, GroupStay.Deposits.CreditLot

    timestamps()
  end
end
