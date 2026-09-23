defmodule GroupStay.Ledger.CreditLot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_on, :date
    field :expires_on, :date
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :allocations, GroupStay.Ledger.CreditAllocation
    has_many :entitlements, GroupStay.Ledger.CreditLotEntitlement

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :issued_on,
      :expires_on,
      :remaining_cents,
      :unrecovered_clawback_cents
    ])
    |> validate_required([
      :guest_id,
      :source_operation_id,
      :issued_on,
      :expires_on,
      :remaining_cents,
      :unrecovered_clawback_cents
    ])
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end
end
