defmodule GroupStay.Groups.PaymentSettlement do
  use Ecto.Schema

  alias GroupStay.Groups.{Group, PaymentDisposition}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payment_settlements" do
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0

    belongs_to :payment_disposition, PaymentDisposition
    belongs_to :group, Group
    timestamps(type: :utc_datetime_usec)
  end
end
