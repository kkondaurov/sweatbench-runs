defmodule GroupStay.CreditApplication do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :credit_lot, GroupStay.CreditLot
    belongs_to :group, GroupStay.Group, foreign_key: :group_record_id
  end
end
