defmodule GroupStay.Credits.CreditLot do
  @moduledoc """
  Hotel credit issued to a guest when a refundable cancellation is settled as credit.

  `remaining_cents` is the part of the lot not currently applied to an active group. The lot is
  usable through the day before `expires_on`.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :source_group_ref, :integer
    field :issued_cents, :integer
    field :remaining_cents, :integer
    field :issued_on, :date
    field :expires_on, :date

    timestamps()
  end
end
