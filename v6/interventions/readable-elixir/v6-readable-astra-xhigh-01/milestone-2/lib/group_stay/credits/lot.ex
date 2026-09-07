defmodule GroupStay.Credits.Lot do
  @moduledoc """
  Credit issued from the cash portion of one refundable cancellation, including
  its one-time bonus. Remaining cents are unallocated credit; expiry is evaluated
  at use or read time. The source and original expiry never change.
  """

  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string

    belongs_to :source_group, GroupStay.Reservations.Group,
      references: :group_id,
      type: :string

    field :source_operation_id, :string
    field :issued_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date

    timestamps(type: :utc_datetime_usec)
  end
end
