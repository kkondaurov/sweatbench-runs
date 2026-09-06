defmodule GroupStay.Deposits.PaymentCashDisposition do
  @moduledoc """
  Current cash dispositions of one durably recorded cash payment.

  `recorded_cents` stays in the payment's stored operation result and is never
  rewritten; the six dispositions tracked here (held cash lives in
  `cash_allocations`) always sum exactly to the recorded amount.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "payment_cash_dispositions" do
    field :operation_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [
      :operation_id,
      :refunded_cents,
      :retained_cents,
      :converted_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_required([:operation_id])
    |> unique_constraint(:operation_id)
  end
end
