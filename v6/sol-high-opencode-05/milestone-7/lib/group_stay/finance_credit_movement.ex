defmodule GroupStay.FinanceCreditMovement do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_credit_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :kind, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end
end
