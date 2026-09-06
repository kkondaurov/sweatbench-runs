defmodule GroupStay.RoomAllocation do
  use Ecto.Schema

  alias GroupStay.{CreditApplication, Group, Payment, Room}

  @moduledoc """
  A chunk of applied funding (cash or hotel credit) held against one room.

  `id` is an incrementing integer so the interactive primary key records the
  fill order: funding operations allocate in operation-processing order and
  reductions / chargebacks remove allocations in reverse fill order.
  """

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_allocations" do
    field :kind, :string
    field :amount_cents, :integer
    field :status, :string, default: "held"

    belongs_to :room, Room
    belongs_to :group, Group
    belongs_to :payment, Payment
    belongs_to :credit_application, CreditApplication

    timestamps()
  end
end
