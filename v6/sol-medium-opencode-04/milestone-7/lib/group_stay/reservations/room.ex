defmodule GroupStay.Reservations.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    belongs_to :group_reservation, GroupStay.Reservations.Group

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :position,
      :room_id,
      :nightly_rate_cents,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :group_reservation_id
    ])
    |> validate_required([
      :position,
      :room_id,
      :nightly_rate_cents,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :group_reservation_id
    ])
  end
end
