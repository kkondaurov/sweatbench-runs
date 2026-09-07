defmodule GroupStay.FinanceReporting.Movement do
  @moduledoc "A signed finance movement; a nil property identifies company-wide credit."
  use Ecto.Schema

  schema "finance_movements" do
    field :posted_on, :date
    field :late_adjustment, :boolean, default: false
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
  end
end
