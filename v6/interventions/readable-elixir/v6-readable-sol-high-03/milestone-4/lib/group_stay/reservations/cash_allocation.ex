defmodule GroupStay.Reservations.CashAllocation do
  @moduledoc "A held portion of one cash funding assigned to an active room."

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.{CashFunding, Room}

  schema "cash_allocations" do
    belongs_to :cash_funding, CashFunding
    belongs_to :room, Room
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attributes) do
    allocation
    |> cast(attributes, [:cash_funding_id, :room_id, :amount_cents])
    |> validate_required([:cash_funding_id, :room_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
