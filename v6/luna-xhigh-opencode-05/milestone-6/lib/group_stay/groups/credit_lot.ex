defmodule GroupStay.Groups.CreditLot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :issued_on, :date
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer

    has_many :allocations, GroupStay.Groups.CreditAllocation, foreign_key: :credit_lot_id
  end

  def changeset(lot, attrs) do
    cast(lot, attrs, [
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :issued_on,
      :expires_on,
      :unrecovered_clawback_cents
    ])
  end
end
