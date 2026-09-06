defmodule GroupStay.Bookings.CashPayment do
  use Ecto.Schema

  @primary_key {:payment_operation_id, :string, autogenerate: false}
  schema "cash_payments" do
    field :original_group_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
  end
end
