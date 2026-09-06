defmodule GroupStay.Credit.Application do
  @moduledoc """
  One portion of a credit lot applied to a group's deposit. Preserved while
  the group is active so the amount can be restored to its lot if the group
  is later cancelled while refundable.
  """

  use Ecto.Schema

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :lot, GroupStay.Credit.Lot, foreign_key: :lot_id

    timestamps(type: :utc_datetime)
  end
end
