defmodule GroupStay.PaymentDisposition do
  use Ecto.Schema

  schema "payment_dispositions" do
    field :recorded_cents, :integer
    field :payment_operation_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    belongs_to :group, GroupStay.Group

    timestamps(type: :utc_datetime)
  end
end
