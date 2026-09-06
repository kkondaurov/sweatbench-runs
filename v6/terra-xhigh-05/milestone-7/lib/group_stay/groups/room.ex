defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "group_rooms" do
    belongs_to :group, Group, foreign_key: :reservation_id, type: :binary_id
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :reservation_id,
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
      :reservation_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> unique_constraint([:reservation_id, :room_id])
  end
end
