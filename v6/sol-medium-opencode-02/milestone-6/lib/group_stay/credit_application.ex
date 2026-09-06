defmodule GroupStay.CreditApplication do
  use Ecto.Schema

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Group
    belongs_to :credit_lot, GroupStay.CreditLot

    timestamps(type: :utc_datetime)
  end
end
