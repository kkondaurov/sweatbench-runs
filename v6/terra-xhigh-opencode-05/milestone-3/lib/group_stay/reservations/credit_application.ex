defmodule GroupStay.Reservations.CreditApplication do
  use Ecto.Schema

  schema "credit_applications" do
    field :group_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Reservations.Group,
      foreign_key: :group_id,
      references: :group_id,
      define_field: false

    belongs_to :credit_lot, GroupStay.Reservations.CreditLot,
      foreign_key: :credit_lot_id,
      define_field: false

    timestamps()
  end
end
