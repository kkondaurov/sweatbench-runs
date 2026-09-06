defmodule GroupStay.CashPayment do
  use Ecto.Schema

  @primary_key {:payment_operation_id, :string, autogenerate: false}
  @foreign_key_type :binary_id

  schema "cash_payments" do
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :participated_in_transfer, :boolean, default: false

    belongs_to :group, GroupStay.Group, foreign_key: :group_record_id
  end
end
