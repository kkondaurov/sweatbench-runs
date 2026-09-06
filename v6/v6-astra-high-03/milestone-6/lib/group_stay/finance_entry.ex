defmodule GroupStay.FinanceEntry do
  @moduledoc false
  use Ecto.Schema

  schema "finance_entries" do
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :movements, :map
  end
end
