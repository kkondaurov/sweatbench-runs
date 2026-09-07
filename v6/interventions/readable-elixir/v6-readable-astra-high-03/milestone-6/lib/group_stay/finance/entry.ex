defmodule GroupStay.Finance.Entry do
  @moduledoc """
  An immutable, signed finance fact committed with its partner operation.
  A nil property identifies company-wide hotel credit. Opening entries are
  balances, not movements. Future expiry entries release unused credit without
  requiring a timer or a mutating report read.
  """
  use Ecto.Schema

  schema "finance_entries" do
    field :operation_id, :string
    field :posted_on, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer
  end
end
