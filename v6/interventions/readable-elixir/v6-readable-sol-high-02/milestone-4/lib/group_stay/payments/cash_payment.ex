defmodule GroupStay.Payments.CashPayment do
  @moduledoc """
  The immutable principal recorded by one cash-payment operation.

  A row without an operation identifier is the senior legacy block reconstructed when room
  accounting was introduced. Its allocations participate in settlement, but it cannot be reduced,
  charged back, or reconciled through the partner operation API.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "cash_payments" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :funding_order, :integer

    belongs_to :group, GroupStay.Reservations.Group,
      references: :group_id,
      foreign_key: :group_id,
      type: :string

    has_many :allocations, GroupStay.Payments.CashAllocation
    has_many :credit_entitlements, GroupStay.Credits.CreditEntitlement
  end

  def creation_changeset(payment, attrs) do
    payment
    |> cast(attrs, [:group_id, :payment_operation_id, :recorded_cents, :funding_order])
    |> validate_required([:group_id, :recorded_cents, :funding_order])
    |> validate_number(:recorded_cents, greater_than: 0)
    |> unique_constraint(:payment_operation_id)
    |> foreign_key_constraint(:group_id)
  end
end
