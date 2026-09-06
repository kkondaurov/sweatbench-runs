defmodule GroupStay.Reservations.CashPayment do
  use Ecto.Schema

  @primary_key {:operation_id, :string, autogenerate: false}

  schema "cash_payments" do
    field :group_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer

    timestamps()
  end
end
