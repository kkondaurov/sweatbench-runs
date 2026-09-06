defmodule GroupStay.Deposits.CreditLot do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer, default: 0
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :allocations, GroupStay.Deposits.CreditAllocation

    timestamps(type: :utc_datetime)
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
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end
end
