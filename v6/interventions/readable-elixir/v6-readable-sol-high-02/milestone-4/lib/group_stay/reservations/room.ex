defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room priced as part of a group reservation.

  `position` preserves the order supplied by the partner. It also defines the
  fill order for cash and hotel credit. Monetary fields are the room's original
  requirement plus the funding currently held while the room is active.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, Ecto.Enum, values: [:active, :cancelled]
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, GroupStay.Reservations.Group,
      references: :group_id,
      foreign_key: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_required([
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_number(:nightly_rate_cents, greater_than: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end

  def funding_changeset(room, cash_delta, credit_delta) do
    change(room,
      cash_paid_cents: room.cash_paid_cents + cash_delta,
      credit_paid_cents: room.credit_paid_cents + credit_delta
    )
  end

  def cancellation_changeset(room) do
    change(room, status: :cancelled, cash_paid_cents: 0, credit_paid_cents: 0)
  end
end
