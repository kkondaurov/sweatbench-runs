defmodule GroupStay.CashPayment do
  @moduledoc "The mutable accounting dispositions of one recorded cash payment."

  use Ecto.Schema

  @primary_key {:payment_operation_id, :string, autogenerate: false}

  schema "cash_payments" do
    field :group_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :charged_back, :boolean, default: false
  end
end
