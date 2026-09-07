defmodule GroupStay.Finance.Entry do
  @moduledoc """
  An immutable, signed finance fact committed with its partner operation.
  A nil property identifies company-wide hotel credit. Opening entries are
  balances, not movements. Future expiry entries release unused credit without
  requiring a timer or a mutating report read.

  Late adjustments identify movements deferred by a period close, independently
  of their signed classification. Entries are never rewritten by a later close.
  """
  use Ecto.Schema

  schema "finance_entries" do
    field :operation_id, :string
    field :posted_on, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end
end
