defmodule GroupStay.Groups.Room do
  @moduledoc """
  A room within a group reservation, kept in the partner's original order.

  A room is `active` until it is cancelled. `cash_paid_cents` and `credit_paid_cents` are the
  funding currently allocated to the room; they are loaded by `GroupStay.Groups`.
  """
  use Ecto.Schema

  schema "group_rooms" do
    field :group_ref, :integer
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_cents, :integer
    field :deposit_cents, :integer
    field :status, :string, default: "active"
    field :cash_paid_cents, :integer, virtual: true, default: 0
    field :credit_paid_cents, :integer, virtual: true, default: 0
  end
end
