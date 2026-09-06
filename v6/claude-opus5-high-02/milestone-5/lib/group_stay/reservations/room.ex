defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room held by a group reservation.

  Lodging and deposit amounts are stored per room because the deposit is rounded room by room
  before it is summed into the group deposit, and because rooms can be settled one at a time.

  `cash_paid_cents` and `credit_paid_cents` are the funding currently held against this room's
  deposit. Settling a room moves that funding on, so a cancelled room holds nothing.
  """

  use Ecto.Schema

  @statuses ~w(active cancelled)

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_cents, :integer
    field :deposit_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, GroupStay.Reservations.Group

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def active?(%__MODULE__{status: status}), do: status == "active"

  @doc """
  Everything currently funding this room's deposit, whatever funded it.
  """
  def paid_cents(%__MODULE__{} = room), do: room.cash_paid_cents + room.credit_paid_cents

  @doc """
  The part of this room's deposit that no funding is held against yet.
  """
  def unfunded_deposit_cents(%__MODULE__{} = room), do: room.deposit_cents - paid_cents(room)
end
