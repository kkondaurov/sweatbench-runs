defmodule GroupStay.Reservations.Room do
  @moduledoc """
  One room in a group and its immutable booking requirement.

  Lodging and deposit amounts remain on a cancelled room for audit. The room's
  status determines whether those amounts contribute to current group totals;
  paid amounts represent only funding still held on an active room.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditAllocation
  alias GroupStay.Payments.CashAllocation
  alias GroupStay.Reservations.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, Group, foreign_key: :group_record_id
    has_many :cash_allocations, CashAllocation, foreign_key: :room_record_id
    has_many :credit_allocations, CreditAllocation, foreign_key: :room_record_id

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :group_record_id,
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
      :group_record_id,
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
