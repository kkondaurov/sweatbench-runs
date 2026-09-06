defmodule GroupStay.Payments.PaymentTransferParticipation do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Payments.PaymentFunding

  schema "payment_transfer_participations" do
    belongs_to :payment_funding, PaymentFunding
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(participation, attrs) do
    participation
    |> cast(attrs, [:payment_funding_id])
    |> validate_required([:payment_funding_id])
    |> unique_constraint(:payment_funding_id)
  end
end
