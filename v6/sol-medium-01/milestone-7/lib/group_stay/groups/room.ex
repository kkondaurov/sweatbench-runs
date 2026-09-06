defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  import Ecto.Changeset

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, GroupStay.Groups.Group

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :group_id,
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
      :group_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
  end
end
