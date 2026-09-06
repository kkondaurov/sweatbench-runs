defmodule GroupStay.Payments.PaymentAccounting do
  use Ecto.Schema

  @primary_key {:payment_operation_id, :string, autogenerate: false}
  schema "payment_accountings" do
    field :original_group_id, :string
    field :recorded_cents, :integer
    field :funding_order, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :has_transferred, :boolean, default: false

    timestamps(type: :utc_datetime)
  end
end
