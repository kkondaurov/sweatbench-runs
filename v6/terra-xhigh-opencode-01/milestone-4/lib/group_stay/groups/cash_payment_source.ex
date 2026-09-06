defmodule GroupStay.Groups.CashPaymentSource do
  use Ecto.Schema

  schema "cash_payment_sources" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer

    belongs_to :group, GroupStay.Groups.Group
  end
end
