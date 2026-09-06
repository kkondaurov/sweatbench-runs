defmodule GroupStay.Groups.CashPaymentSettlement do
  @moduledoc """
  The cash one payment settled under one group, kept per settling group.

  Funding from a payment can settle in any group that currently holds it,
  so a chargeback reclassifies each settled portion where it was recorded.
  """

  use Ecto.Schema

  alias GroupStay.Groups.{CashPayment, Group}

  schema "cash_payment_settlements" do
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0

    belongs_to :cash_payment, CashPayment
    belongs_to :group, Group

    timestamps()
  end
end
