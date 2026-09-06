defmodule GroupStay.Schemas.FinanceMovement do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer

    timestamps()
  end
end
