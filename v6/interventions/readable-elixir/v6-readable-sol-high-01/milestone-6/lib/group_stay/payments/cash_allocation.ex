defmodule GroupStay.Payments.CashAllocation do
  @moduledoc "Cash held against one active room's deposit."

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Payments.CashPayment
  alias GroupStay.Reservations.{Group, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_allocations" do
    field :funding_order, :integer
    field :allocation_order, :integer
    field :amount_cents, :integer
    belongs_to :group, Group, foreign_key: :group_record_id
    belongs_to :room, Room, foreign_key: :room_record_id
    belongs_to :cash_payment, CashPayment

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_record_id,
      :room_record_id,
      :cash_payment_id,
      :funding_order,
      :allocation_order,
      :amount_cents
    ])
    |> validate_required([
      :group_record_id,
      :room_record_id,
      :funding_order,
      :allocation_order,
      :amount_cents
    ])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
