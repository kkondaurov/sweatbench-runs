defmodule GroupStay.Credit.Application do
  @moduledoc """
  The amount of one credit lot currently funding one room's deposit in one
  active group.

  Applications preserve which lots funded which room, and which operation
  applied them, so a partial room settlement can return exactly those amounts
  to their lots. Applications written before attribution existed keep nil
  `operation_id`/`room_id` and form their group's unattributed senior block.
  An application's expiry is paused: it exists only while its group is active.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_credit_applications" do
    field :amount_cents, :integer
    field :operation_id, :string

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :lot, GroupStay.Credit.Lot
    belongs_to :room, GroupStay.Groups.Room

    timestamps(type: :utc_datetime)
  end
end
