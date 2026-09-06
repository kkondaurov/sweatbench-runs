defmodule GroupStay.Finance.CreditApplication do
  @moduledoc """
  Records which credit lot funded which group and how much, so the amount can
  be restored to its original lot if the group is later cancelled while
  refundable.

  The status is `"active"` while the credit funds the group, then becomes
  `"restored"` or `"consumed"` when the group's cancellation settles it.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer
    field :status, :string, default: "active"

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :lot, GroupStay.Finance.CreditLot

    timestamps(type: :utc_datetime)
  end
end
