defmodule GroupStay.Credit.CreditApplication do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :lot, CreditLot
    belongs_to :group, Group

    timestamps()
  end
end
