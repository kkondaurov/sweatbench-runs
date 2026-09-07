defmodule GroupStay.Deposits.CreditEntitlement do
  @moduledoc "The bonus-inclusive share of a cancellation credit lot attributable to a payment."

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Deposits.CreditLot

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :issued_cents, :integer
    field :revoked_cents, :integer, default: 0
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:credit_lot_id, :payment_operation_id, :issued_cents, :revoked_cents])
    |> validate_required([:credit_lot_id, :issued_cents, :revoked_cents])
    |> validate_number(:issued_cents, greater_than_or_equal_to: 0)
    |> validate_number(:revoked_cents, greater_than_or_equal_to: 0)
  end
end
