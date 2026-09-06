defmodule GroupStay.Reservations.PaymentTransferParticipation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "payment_transfer_participations" do
    belongs_to :cash_payment, GroupStay.Reservations.CashPayment
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(participation, attrs) do
    participation
    |> cast(attrs, [:cash_payment_id])
    |> validate_required([:cash_payment_id])
    |> unique_constraint(:cash_payment_id)
  end
end
