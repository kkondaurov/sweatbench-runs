defmodule GroupStay.Bookings.CreditLot do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Bookings.CreditAllocation

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :allocations, CreditAllocation
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
  end

  def balance_changeset(lot, remaining_cents) do
    cast(lot, %{remaining_cents: remaining_cents}, [:remaining_cents])
  end
end
