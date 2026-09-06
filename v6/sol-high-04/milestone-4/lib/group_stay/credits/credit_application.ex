defmodule GroupStay.Credits.CreditApplication do
  use Ecto.Schema

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :credit_lot, GroupStay.Credits.CreditLot

    timestamps(type: :utc_datetime)
  end
end
