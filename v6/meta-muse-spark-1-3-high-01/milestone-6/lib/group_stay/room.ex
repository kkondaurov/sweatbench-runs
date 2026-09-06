defmodule GroupStay.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :lodging_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :status, :string, default: "active"

    belongs_to :group, GroupStay.Group, foreign_key: :group_db_id

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :group_db_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :lodging_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :status
    ])
    |> validate_required([:group_db_id, :room_id, :nightly_rate_cents, :position])
  end
end
