defmodule GroupStay.Payments.Payment do
  @moduledoc """
  Current cash dispositions for a durable, applied payment. The immutable partner
  result lives in Operations; this account changes as cash is settled or reversed.
  Held cash is the recorded amount less all permanent dispositions.
  """
  use Ecto.Schema

  schema "cash_payments" do
    field :payment_operation_id, :string
    field :original_group_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
  end

  @dispositions ~w(refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a
  def held(payment),
    do: payment.recorded_cents - Enum.sum(Enum.map(@dispositions, &Map.fetch!(payment, &1)))

  def statement(payment) do
    payment
    |> Map.take([:payment_operation_id, :original_group_id, :recorded_cents | @dispositions])
    |> Map.put(:held_cents, held(payment))
  end
end
