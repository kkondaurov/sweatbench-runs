defmodule GroupStay.FinanceEvent do
  @moduledoc false

  use Ecto.Schema

  schema "finance_events" do
    field :operation_id, :string
    field :operation_type, :string
    field :natural_posting_on, :date
    field :posting_on, :date
    field :cash_json, :string
    field :credit_json, :string
    field :cash_details_json, :string
    field :credit_lot_deltas_json, :string
  end
end
