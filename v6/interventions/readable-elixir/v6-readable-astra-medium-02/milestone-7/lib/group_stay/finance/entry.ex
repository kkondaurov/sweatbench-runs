defmodule GroupStay.Finance.Entry do
  @moduledoc "A signed reporting movement, or an inception balance, committed with its operation."
  use Ecto.Schema

  schema "finance_entries" do
    field :posting_on, :date
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end
end
