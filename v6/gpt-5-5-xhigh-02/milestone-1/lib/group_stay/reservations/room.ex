defmodule GroupStay.Reservations.Room do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "group_rooms" do
    field :room_id, :string
    field :position, :integer
    field :nightly_rate_cents, :integer
    field :lodging_amount_cents, :integer
    field :deposit_due_cents, :integer

    belongs_to :group, Group, foreign_key: :group_pk_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(
    group_pk_id
    room_id
    position
    nightly_rate_cents
    lodging_amount_cents
    deposit_due_cents
  )a

  def changeset(room, attrs) do
    room
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:nightly_rate_cents, greater_than: 0)
    |> validate_number(:lodging_amount_cents, greater_than: 0)
    |> validate_number(:deposit_due_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:group_pk_id)
    |> unique_constraint([:group_pk_id, :room_id])
  end
end
