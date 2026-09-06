defmodule GroupStay.FinanceCreditEvent do
  use Ecto.Schema

  schema "finance_credit_events" do
    field :operation_id, :string
    field :credit_lot_id, :integer
    field :posting_on, :date
    field :available_delta_cents, :integer, default: 0
  end
end
