defmodule GroupStay.Schemas.CreditApplication do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    belongs_to :group, GroupStay.Schemas.Group
    belongs_to :credit_lot, GroupStay.Schemas.CreditLot
    field :amount_cents, :integer

    timestamps()
  end
end
