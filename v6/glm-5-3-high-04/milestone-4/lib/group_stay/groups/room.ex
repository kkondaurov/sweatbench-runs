defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    # Null for rooms of groups whose funding has not been brought forward
    # yet; the amount is derived from the group until then.
    field :deposit_due_cents, :integer

    belongs_to :group, GroupStay.Groups.Group

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :deposit_due_cents,
      :group_id
    ])
    |> validate_required([:room_id, :nightly_rate_cents, :position, :group_id])
    |> unique_constraint([:group_id, :room_id])
  end
end
