defmodule GroupStay.Credits.CreditLot do
  @moduledoc """
  A guest credit balance created by a refundable cancellation.

  `remaining_cents` includes both available value and value currently applied
  to active groups. Allocations pause expiry without removing the liability.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditAllocation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_on, :date
    field :expires_on, :date
    field :remaining_cents, :integer

    has_many :allocations, CreditAllocation

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :issued_on,
      :expires_on,
      :remaining_cents
    ])
    |> validate_required([
      :guest_id,
      :source_operation_id,
      :issued_on,
      :expires_on,
      :remaining_cents
    ])
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end
end
