defmodule GroupStay.Groups.CreditLot do
  @moduledoc """
  A lot of hotel credit issued to a guest by a cancellation.

  `remaining_cents` is the part of the lot that is available again. Amounts
  currently applied to an active group are tracked separately in
  `GroupStay.Groups.GroupCreditApplication` and are excluded from
  `remaining_cents` while they fund that group.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer, default: 0
    field :issued_on, :date
    field :expires_on, :date

    timestamps(type: :utc_datetime)
  end
end
