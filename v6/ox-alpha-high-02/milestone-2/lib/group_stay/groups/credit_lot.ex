defmodule GroupStay.Groups.CreditLot do
  @moduledoc """
  A lot of hotel credit issued to a guest by a refundable cancellation.

  The lot is available through the day before `expires_on` and expires on
  `expires_on`. Portions applied to an active group keep their value while
  they fund that group.
  """

  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    timestamps()
  end
end
