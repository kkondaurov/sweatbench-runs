defmodule GroupStay.Groups.Room do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Groups.Group

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end
end
