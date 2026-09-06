defmodule GroupStay.Groups.CreditApplication do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :lot, GroupStay.Groups.CreditLot,
      foreign_key: :lot_id,
      references: :id,
      type: :binary_id
  end
end
