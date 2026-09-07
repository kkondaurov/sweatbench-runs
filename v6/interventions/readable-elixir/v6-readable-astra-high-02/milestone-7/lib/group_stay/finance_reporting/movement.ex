defmodule GroupStay.FinanceReporting.Movement do
  @moduledoc """
  A signed journal entry committed with its originating partner operation.
  A nil property identifies company-wide credit; cash always names a property.
  Scheduled expiry entries can be offset when available credit is used or revoked.
  The late-adjustment flag is fixed at insertion and applies only when a period
  close moved this entry's posting date forward.
  """
  use Ecto.Schema

  schema "finance_movements" do
    field :operation_id, :string
    field :posted_on, :date
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end
end
