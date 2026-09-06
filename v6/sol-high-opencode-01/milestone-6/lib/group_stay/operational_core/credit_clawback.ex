defmodule GroupStay.OperationalCore.CreditClawback do
  use Ecto.Schema

  schema "credit_clawbacks" do
    field :source_operation_id, :string
    field :amount_cents, :integer
  end
end
