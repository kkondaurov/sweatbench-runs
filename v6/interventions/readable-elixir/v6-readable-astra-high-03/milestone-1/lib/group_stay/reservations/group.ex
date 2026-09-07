defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group's booking and deposit account. Rooms are an ordered snapshot of the
  partner's booking, stored together because they share one reservation lifecycle.

  Cancellation clears the deposit obligation and applied cash, moving that cash
  into the permanent refunded or retained settlement totals.
  """
  use Ecto.Schema

  @primary_key {:group_id, :string, autogenerate: false}
  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0

    embeds_many :rooms, Room, primary_key: false do
      field :room_id, :string
      field :nightly_rate_cents, :integer
    end
  end

  def outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents
end
