defmodule GroupStay.FinanceMovement do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_movements" do
    field :posting_date, :date
    field :kind, :string
    field :property_id, :string
    field :amount_cents, :integer
    field :is_late, :boolean, default: false

    timestamps()
  end
end
