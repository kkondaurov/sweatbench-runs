defmodule GroupStay.Groups.FinanceCreditMovement do
  use Ecto.Schema

  schema "finance_credit_movements" do
    field :posting_on, :date
    field :movement_type, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean
  end
end
