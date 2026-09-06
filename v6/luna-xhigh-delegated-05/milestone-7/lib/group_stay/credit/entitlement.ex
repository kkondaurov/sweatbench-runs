defmodule GroupStay.Credit.Entitlement do
  use Ecto.Schema

  alias GroupStay.Credit.Lot

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :entitlement_cents, :integer
    field :revoked_cents, :integer

    belongs_to :lot, Lot

    timestamps(type: :utc_datetime_usec)
  end
end
