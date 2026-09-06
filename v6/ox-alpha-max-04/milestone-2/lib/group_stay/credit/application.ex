defmodule GroupStay.Credit.Application do
  @moduledoc """
  The amount of one credit lot currently funding one active group's deposit.

  Applications preserve which lots funded a group so those amounts can be
  restored to their lots when the group is cancelled while refundable, or
  consumed when it is not. An application's expiry is paused: it exists only
  while its group is active.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :lot, GroupStay.Credit.Lot

    timestamps(type: :utc_datetime)
  end
end
