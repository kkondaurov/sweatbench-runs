defmodule GroupStay.HotelCredit.Lot do
  @moduledoc """
  Credit issued from the cash portion of one refundable cancellation.
  Remaining credit excludes amounts redeemed into reservations. Expiry applies
  only to that remaining balance; redeemed credit keeps its original lot identity.
  Partner operation IDs are correlation values and need not be globally unique.
  """

  use Ecto.Schema

  schema "credit_lots" do
    belongs_to :source_group, GroupStay.Reservations.Group, type: :string, references: :group_id
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date
  end
end
