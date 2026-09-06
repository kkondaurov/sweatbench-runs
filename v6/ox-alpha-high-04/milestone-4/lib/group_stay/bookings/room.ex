defmodule GroupStay.Bookings.Room do
  @moduledoc """
  A room belonging to a group reservation. Rooms keep their original order
  through the `position` column.

  Each room tracks the deposit it requires and the cash and hotel credit
  currently allocated to it; the room's `status` is `active` or `cancelled`.
  """

  use Ecto.Schema

  @statuses ~w(active cancelled)

  schema "rooms" do
    field :group_id, :string
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
end
