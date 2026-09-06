defmodule GroupStay.Credit.Application do
  @moduledoc """
  A portion of a credit lot applied to a group's deposit. Recorded so the
  amount can be restored to its original lot if the group is later cancelled
  while refundable.
  """

  use Ecto.Schema

  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "credit_applications" do
    field :amount_cents, :integer
    belongs_to :group, Group, type: :binary_id
    belongs_to :credit_lot, Lot, type: :binary_id

    timestamps(type: :utc_datetime)
  end
end
