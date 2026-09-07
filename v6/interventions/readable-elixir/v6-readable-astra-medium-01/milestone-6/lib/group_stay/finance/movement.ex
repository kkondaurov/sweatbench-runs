defmodule GroupStay.Finance.Movement do
  @moduledoc "A signed finance classification; a nil property denotes company-wide credit."
  use Ecto.Schema

  schema "finance_movements" do
    field :posted_on, :date
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
  end
end
