defmodule GroupStay.Reservations.PaymentSettlement do
  @moduledoc "Settled cash by payment and settlement group, excluding charged-back cash."
  use Ecto.Schema

  schema "payment_settlements" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
  end
end
