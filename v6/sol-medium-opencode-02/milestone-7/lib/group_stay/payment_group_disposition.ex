defmodule GroupStay.PaymentGroupDisposition do
  use Ecto.Schema

  schema "payment_group_dispositions" do
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0

    belongs_to :payment_disposition, GroupStay.PaymentDisposition
    belongs_to :group, GroupStay.Group

    timestamps(type: :utc_datetime)
  end
end
