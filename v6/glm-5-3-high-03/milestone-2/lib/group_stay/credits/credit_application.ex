defmodule GroupStay.Credits.CreditApplication do
  @moduledoc """
  Records which credit lot funded a group, and for how much, so the amount
  can be restored to its original lot if the group is later cancelled while
  refundable.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :credit_lot, GroupStay.Credits.CreditLot

    timestamps(type: :utc_datetime)
  end
end
