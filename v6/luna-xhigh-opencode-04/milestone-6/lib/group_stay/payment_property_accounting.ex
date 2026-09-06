defmodule GroupStay.PaymentPropertyAccounting do
  use Ecto.Schema

  schema "payment_property_accountings" do
    field :payment_operation_id, :string
    field :held_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer

    belongs_to :group, GroupStay.Group
  end
end
