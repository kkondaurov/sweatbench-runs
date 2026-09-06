defmodule GroupStay.PaymentAccount do
  use Ecto.Schema

  schema "payment_accounts" do
    field :operation_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    belongs_to :operation_record, GroupStay.OperationRecord
    belongs_to :group, GroupStay.Group, type: :string

    timestamps(type: :utc_datetime)
  end
end
