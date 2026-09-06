defmodule GroupStay.Finance.CreditMovement do
  use Ecto.Schema

  schema "finance_credit_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :category, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
