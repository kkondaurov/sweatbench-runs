defmodule GroupStay.Finance.Movement do
  @moduledoc "A signed journal entry; a nil property identifies company-wide hotel credit."
  use Ecto.Schema

  schema "finance_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :category, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end
end
