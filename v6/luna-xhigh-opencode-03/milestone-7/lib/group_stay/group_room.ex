defmodule GroupStay.GroupRoom do
  use Ecto.Schema

  import Ecto.Changeset

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :deposit_due_cents, :integer
    field :status, :string
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer

    belongs_to :group, GroupStay.Group, foreign_key: :group_record_id
    has_many :cash_allocations, GroupStay.CashAllocation, foreign_key: :group_room_id
    has_many :credit_allocations, GroupStay.GroupCreditAllocation, foreign_key: :group_room_id
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :group_record_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :deposit_due_cents,
      :status,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_required([
      :group_record_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :deposit_due_cents,
      :status,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> unique_constraint(:room_id, name: :group_rooms_group_record_id_room_id_index)
  end
end
