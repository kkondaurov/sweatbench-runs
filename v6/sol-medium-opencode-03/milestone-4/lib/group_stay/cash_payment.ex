defmodule GroupStay.CashPayment do
  use Ecto.Schema

  alias GroupStay.{CashAllocation, CreditEntitlement, Group}

  schema "cash_payments" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    belongs_to :group, Group, foreign_key: :group_record_id
    has_many :allocations, CashAllocation
    has_many :credit_entitlements, CreditEntitlement

    timestamps(type: :utc_datetime)
  end
end
