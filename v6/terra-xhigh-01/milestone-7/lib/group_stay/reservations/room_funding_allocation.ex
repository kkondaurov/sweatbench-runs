defmodule GroupStay.Reservations.RoomFundingAllocation do
  @moduledoc false

  use Ecto.Schema

  schema "room_funding_allocations" do
    field :funding_type, :string
    field :amount_cents, :integer

    belongs_to :group_room, GroupStay.Reservations.GroupRoom
    belongs_to :cash_payment, GroupStay.Reservations.CashPayment
    belongs_to :group_credit_payment, GroupStay.Reservations.GroupCreditPayment

    timestamps(type: :utc_datetime)
  end
end
