defmodule GroupStay.HotelCredit.Application do
  @moduledoc """
  The historical amount a credit lot contributed to a group's deposit.
  Applications remain after settlement for traceability. Current room allocations
  determine liability and paused expiry; a partially cancelled group may have
  already returned or consumed some of this historical amount.
  """

  use Ecto.Schema

  schema "credit_applications" do
    belongs_to :group, GroupStay.Reservations.Group, type: :string, references: :group_id
    belongs_to :credit_lot, GroupStay.HotelCredit.Lot
    field :amount_cents, :integer
  end
end
