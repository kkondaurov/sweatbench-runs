defmodule GroupStay.Reservations.FinanceCreditExpirySchedule do
  @moduledoc """
  The available portion of a credit lot that is eligible to expire.

  `opening_available_cents` is fixed at reporting inception (or zero for a lot
  issued later). Dated adjustments track applications, restorations, and
  revocations so a late submission can correctly revise an earlier expiry.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.{CreditLot, FinanceCreditExpiryAdjustment}

  schema "finance_credit_expiry_schedules" do
    belongs_to :credit_lot, CreditLot
    field :expires_on, :date
    field :opening_available_cents, :integer, default: 0
    has_many :adjustments, FinanceCreditExpiryAdjustment, foreign_key: :credit_expiry_schedule_id
  end

  def changeset(schedule, attributes) do
    schedule
    |> cast(attributes, [:credit_lot_id, :expires_on, :opening_available_cents])
    |> validate_required([:credit_lot_id, :expires_on, :opening_available_cents])
    |> validate_number(:opening_available_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:credit_lot_id)
  end
end
