defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A single room held by a group reservation.

  `lodging_cents` and `deposit_cents` are stored per room because the deposit is
  rounded room by room before it is summed into the group total. A cancelled room
  no longer owes its deposit and no longer counts towards the group's totals.

  `cash_paid_cents` and `credit_paid_cents` are filled in for reads by
  `GroupStay.Funding.with_room_funding/1`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  @statuses ~w(active cancelled)

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_cents, :integer
    field :deposit_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"

    field :cash_paid_cents, :integer, virtual: true, default: 0
    field :credit_paid_cents, :integer, virtual: true, default: 0

    belongs_to :group, Group, foreign_key: :group_ref

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:room_id, :nightly_rate_cents, :lodging_cents, :deposit_cents, :position, :status]

  def changeset(room, attrs) do
    room
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:status, @statuses)
  end
end
