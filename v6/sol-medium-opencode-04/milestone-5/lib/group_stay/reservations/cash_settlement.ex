defmodule GroupStay.Reservations.CashSettlement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cash_settlements" do
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    belongs_to :cash_payment, GroupStay.Reservations.CashPayment
    belongs_to :group_reservation, GroupStay.Reservations.Group
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(settlement, attrs) do
    settlement
    |> cast(attrs, [
      :cash_payment_id,
      :group_reservation_id,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
    |> validate_required([:cash_payment_id, :group_reservation_id])
    |> unique_constraint([:cash_payment_id, :group_reservation_id])
  end
end
