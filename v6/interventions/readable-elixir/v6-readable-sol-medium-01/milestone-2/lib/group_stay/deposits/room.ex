defmodule GroupStay.Deposits.Room do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Deposits.Group

  schema "rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    belongs_to :group, Group, foreign_key: :group_record_id

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:group_record_id, :position, :room_id, :nightly_rate_cents])
    |> validate_required([:group_record_id, :position, :room_id, :nightly_rate_cents])
  end
end
