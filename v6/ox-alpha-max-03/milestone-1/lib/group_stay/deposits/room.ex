defmodule GroupStay.Deposits.Room do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "group_rooms" do
    belongs_to :group, GroupStay.Deposits.Group
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:position, :room_id, :nightly_rate_cents])
    |> validate_required([:position, :room_id, :nightly_rate_cents])
    |> validate_number(:nightly_rate_cents, greater_than: 0)
    |> unique_constraint([:group_id, :position])
  end
end
