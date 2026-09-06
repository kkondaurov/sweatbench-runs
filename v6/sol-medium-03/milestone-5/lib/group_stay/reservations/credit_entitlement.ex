defmodule GroupStay.Reservations.CreditEntitlement do
  use Ecto.Schema

  alias GroupStay.Reservations.CreditLot

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :amount_cents, :integer

    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end
end
