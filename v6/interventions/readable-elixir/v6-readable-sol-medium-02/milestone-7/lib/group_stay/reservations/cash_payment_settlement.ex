defmodule GroupStay.Reservations.CashPaymentSettlement do
  @moduledoc """
  Locates a payment's settled cash on the group whose cancellation settled it.

  A payment can fund another group after a transfer. Keeping this attribution allows a later
  chargeback to reclassify the correct group's ledger fields and revision.
  """

  use Ecto.Schema

  alias GroupStay.Reservations.{CashPaymentAccounting, GroupReservation}

  schema "cash_payment_settlements" do
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0

    belongs_to :payment_accounting, CashPaymentAccounting

    belongs_to :group, GroupReservation,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end
end
