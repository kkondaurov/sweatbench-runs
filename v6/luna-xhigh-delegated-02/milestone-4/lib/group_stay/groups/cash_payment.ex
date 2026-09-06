defmodule GroupStay.Groups.CashPayment do
  @moduledoc "Current dispositions for a durably recorded cash payment."

  use Ecto.Schema
  import Ecto.Changeset

  schema "cash_payments" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :payment_operation_id,
      :group_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_required([:payment_operation_id, :group_id, :recorded_cents])
    |> unique_constraint(:payment_operation_id)
  end
end
