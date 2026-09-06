defmodule GroupStay.Groups.Room do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:room_id, :nightly_rate_cents, :status, :deposit_due_cents])
    |> validate_required([:room_id, :nightly_rate_cents])
  end
end
