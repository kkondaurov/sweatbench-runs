defmodule GroupStay.FinanceEntry do
  @moduledoc false
  use Ecto.Schema

  schema "finance_entries" do
    field :operation_id, :string
    field :posted_on, :date
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end
end
