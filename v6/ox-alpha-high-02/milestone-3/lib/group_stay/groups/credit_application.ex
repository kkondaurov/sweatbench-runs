defmodule GroupStay.Groups.CreditApplication do
  @moduledoc """
  Records which credit lot funded a group and by how much, so the amounts
  can be restored if the group is later cancelled while refundable.
  """

  use Ecto.Schema

  schema "credit_applications" do
    belongs_to :group, GroupStay.Groups.Group
    belongs_to :credit_lot, GroupStay.Groups.CreditLot
    field :amount_cents, :integer

    timestamps()
  end
end
