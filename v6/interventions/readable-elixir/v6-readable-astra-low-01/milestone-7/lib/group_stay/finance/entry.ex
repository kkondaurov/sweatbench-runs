defmodule GroupStay.Finance.Entry do
  @moduledoc "A signed reporting movement; a nil property identifies company-wide credit."
  use Ecto.Schema

  schema "finance_entries" do
    field :posted_on, :date
    field :late_adjustment, :boolean, default: false
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
  end
end
