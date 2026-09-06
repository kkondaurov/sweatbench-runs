defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation: the rooms, the deposit they require, and the cash
  applied against that deposit.
  """

  use Ecto.Schema

  alias GroupStay.Groups.{CashPayment, CreditApplication, Room}

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :arrival_on, :date
    field :departure_on, :date
    field :booked_on, :date
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :cash_reduced_cents, :integer, default: 0
    field :cash_charged_back_cents, :integer, default: 0

    has_many :rooms, Room
    has_many :cash_payments, CashPayment
    has_many :credit_applications, CreditApplication

    timestamps()
  end
end
