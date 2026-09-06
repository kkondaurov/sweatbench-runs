defmodule GroupStay.Groups.ConversionContribution do
  use Ecto.Schema

  alias GroupStay.Groups.{CreditLot, PaymentDisposition}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversion_contributions" do
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :position, :integer
    belongs_to :credit_lot, CreditLot
    belongs_to :payment_disposition, PaymentDisposition
    timestamps(type: :utc_datetime_usec)
  end
end
