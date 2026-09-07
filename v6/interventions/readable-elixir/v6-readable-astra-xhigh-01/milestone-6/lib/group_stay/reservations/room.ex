defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room's agreed nightly rate and its position in the partner's original room list.
  Room identifiers are unique within a group, rather than across properties or groups.
  """

  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, Ecto.Enum, values: [:active, :cancelled], default: :active
    field :lodging_total_cents, :integer, virtual: true
    field :deposit_due_cents, :integer, virtual: true
    field :cash_paid_cents, :integer, virtual: true, default: 0
    field :credit_paid_cents, :integer, virtual: true, default: 0
    belongs_to :group, GroupStay.Reservations.Group, references: :group_id, type: :string
  end
end
