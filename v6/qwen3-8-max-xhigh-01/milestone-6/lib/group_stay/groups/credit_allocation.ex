defmodule GroupStay.Groups.CreditAllocation do
  @moduledoc """
  A unit of hotel credit from one credit application held on (or settled from)
  one room.

  Credit keeps its lot identity so a refundable settlement can restore it to its
  original lot and expiry. `state` is `"held"` while it funds an active room,
  `"restored"` when returned to its lot, and `"consumed"` when forfeited by a
  non-refundable settlement.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CreditApplication, CreditLot, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_allocations" do
    field :amount_cents, :integer
    field :state, :string, default: "held"
    field :seq, :integer

    belongs_to :room, Room
    belongs_to :credit_application, CreditApplication
    belongs_to :lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = allocation, attrs) do
    allocation
    |> cast(attrs, [:room_id, :credit_application_id, :lot_id, :amount_cents, :state, :seq])
    |> validate_required([:room_id, :lot_id, :amount_cents, :state, :seq])
  end
end
