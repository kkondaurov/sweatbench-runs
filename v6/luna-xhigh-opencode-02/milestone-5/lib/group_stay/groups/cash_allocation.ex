defmodule GroupStay.Groups.CashAllocation do
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :integer
    field :payment_operation_id, :string
    field :original_cents, :integer
    field :held_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer
    field :transferred, :boolean, default: false
    field :allocation_order, :integer
  end
end
