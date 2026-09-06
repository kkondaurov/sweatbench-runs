defmodule GroupStay.Groups.GroupCreditApplication do
  @moduledoc """
  Records which credit lot funded a group and for how much, so applied credit
  can be restored to its original lot if the group is later cancelled while
  refundable.
  """

  use Ecto.Schema

  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_credit_applications" do
    belongs_to :group, Group
    belongs_to :credit_lot, CreditLot
    field :amount_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
