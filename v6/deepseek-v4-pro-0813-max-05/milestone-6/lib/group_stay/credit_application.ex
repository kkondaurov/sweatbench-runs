defmodule GroupStay.CreditApplication do
  use Ecto.Schema

  alias GroupStay.{CreditLot, Group}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer
    field :status, :string, default: "applied"
    field :operation_id, :string

    belongs_to :lot, CreditLot
    belongs_to :group, Group

    timestamps()
  end
end
