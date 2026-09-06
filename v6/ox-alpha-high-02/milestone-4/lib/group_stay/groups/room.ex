defmodule GroupStay.Groups.Room do
  @moduledoc """
  A room represented by a group reservation.

  Rooms carry the lodging and deposit amounts used to calculate the group
  requirement, plus the cash and credit currently held on the room.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    belongs_to :group, GroupStay.Groups.Group
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    timestamps()
  end

  def changeset(room, attrs) do
    cast(room, attrs, [
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_required([:room_id, :nightly_rate_cents, :status, :deposit_due_cents])
  end
end
