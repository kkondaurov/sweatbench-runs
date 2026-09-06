defmodule GroupStay.CreditLot do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer

    has_many :allocations, GroupStay.GroupCreditAllocation, foreign_key: :credit_lot_id
    has_many :entitlements, GroupStay.CreditLotEntitlement, foreign_key: :credit_lot_id
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
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
  end
end
