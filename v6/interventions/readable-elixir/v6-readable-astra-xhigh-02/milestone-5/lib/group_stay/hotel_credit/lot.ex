defmodule GroupStay.HotelCredit.Lot do
  @moduledoc """
  Credit issued from the cash portion of one refundable cancellation.
  Remaining credit excludes amounts redeemed into reservations. Expiry applies
  only to that remaining balance; redeemed credit keeps its original lot identity.
  Legacy lots may share a source operation reference. Keep their distinct lot IDs:
  durable idempotency applies only to operations received after its rollout.
  """

  use Ecto.Schema

  schema "credit_lots" do
    belongs_to :source_group, GroupStay.Reservations.Group, type: :string, references: :group_id
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_cents, :integer
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0
    field :expires_on, :date
  end
end
