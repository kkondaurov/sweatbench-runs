defmodule GroupStay.Groups.Room do
  @moduledoc """
  A single room inside a group reservation, in booking order.

  Rooms carry their own lodging and deposit amounts; group totals are sums of
  the active rooms. `cash_paid_cents` and `credit_paid_cents` are virtual:
  they are derived from the room's held funding allocations and are zero for
  cancelled rooms.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{Group, RoomFunding}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :cash_converted_cents, :integer, default: 0

    field :cash_paid_cents, :integer, virtual: true, default: 0
    field :credit_paid_cents, :integer, virtual: true, default: 0

    belongs_to :group, Group
    has_many :room_fundings, RoomFunding

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :refunded_cents,
      :retained_cents,
      :cash_converted_cents
    ])
    |> validate_required([
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_inclusion(:status, ~w(active cancelled))
  end
end
