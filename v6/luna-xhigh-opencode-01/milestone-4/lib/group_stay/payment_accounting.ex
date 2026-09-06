defmodule GroupStay.PaymentAccounting do
  use Ecto.Schema

  @primary_key {:payment_operation_id, :string, autogenerate: false}

  schema "payment_accountings" do
    field :group_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer
  end
end
