defmodule GroupStay.Bookings.CreditLot do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Bookings.{CreditAllocation, CreditEntitlement}

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :allocations, CreditAllocation
    has_many :entitlements, CreditEntitlement
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :expires_on,
      :unrecovered_clawback_cents
    ])
    |> validate_required([
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :expires_on,
      :unrecovered_clawback_cents
    ])
  end

  def balance_changeset(lot, remaining_cents) do
    cast(lot, %{remaining_cents: remaining_cents}, [:remaining_cents])
  end
end
