defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room priced for the entire group stay. Position preserves partner input order;
  room identifiers are unique within their group, not across properties or groups.
  """

  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :position, :integer
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, virtual: true, default: 0
    field :credit_paid_cents, :integer, virtual: true, default: 0
    belongs_to :group, GroupStay.Reservations.Group, type: :string, references: :group_id
    has_many :allocations, GroupStay.Accounting.Allocation
  end
end
