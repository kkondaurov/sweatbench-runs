defmodule GroupStay.Bookings.Group do
  @moduledoc """
  A group reservation. `group_id` is a partner-supplied identifier and is the
  primary key.
  """

  use Ecto.Schema

  @rate_plans ~w(flexible advance_purchase)
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
    # Cash and hotel credit applied to the deposit. `deposit_paid_cents` is
    # always their sum. Policy version is derived from `rate_plan` plus
    # `booked_on`, which never change once the group is opened.
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    has_many :rooms, GroupStay.Bookings.Room, foreign_key: :group_id

    timestamps(type: :utc_datetime_usec)
  end

  def rate_plans, do: @rate_plans
end
