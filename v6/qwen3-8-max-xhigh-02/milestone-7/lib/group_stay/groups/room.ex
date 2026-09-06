defmodule GroupStay.Groups.Room do
  @moduledoc """
  One room within a group reservation, kept in the order supplied by the
  partner.

  A room carries its own lodging and deposit amounts and the funding
  currently applied to its deposit. Group totals are sums of the active
  rooms.
  """

  use Ecto.Schema

  alias GroupStay.Groups.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_cents, :integer
    field :deposit_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, Group

    timestamps()
  end
end
