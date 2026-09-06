defmodule GroupStay.GroupRoom do
  use Ecto.Schema

  import Ecto.Changeset

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group_reservation, GroupStay.GroupReservation

    timestamps(type: :utc_datetime)
  end

  def create_changeset(room, attrs) do
    room
    |> cast(attrs, [
      :group_reservation_id,
      :position,
      :room_id,
      :nightly_rate_cents,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_required([
      :group_reservation_id,
      :position,
      :room_id,
      :nightly_rate_cents,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> unique_constraint([:group_reservation_id, :room_id])
    |> unique_constraint([:group_reservation_id, :position])
  end
end
