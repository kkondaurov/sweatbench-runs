defmodule GroupStay.Groups.GroupCreditApplication do
  @moduledoc """
  The portion of a credit lot currently applied to an active group's deposit.
  It exists so the amount can be restored to its original lot when the group is
  cancelled while refundable. Rows are removed when their group settles.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "group_credit_applications" do
    field :applied_cents, :integer, default: 0

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime)
  end
end
