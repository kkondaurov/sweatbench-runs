defmodule GroupStay.Room do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_cents, :integer
    field :deposit_due_cents, :integer

    belongs_to :group, GroupStay.Group, foreign_key: :group_record_id
    has_many :funding_allocations, GroupStay.RoomFundingAllocation, foreign_key: :room_record_id
  end
end
