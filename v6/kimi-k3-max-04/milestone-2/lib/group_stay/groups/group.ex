defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation with the deposit records GroupStay owns.

  Monetary totals are integer cents. `lodging_total_cents` and
  `deposit_due_cents` are fixed when the group is opened; `deposit_paid_cents`
  grows as cash or hotel credit is applied, split into `cash_paid_cents` and
  `credit_paid_cents`. On cancellation the paid cash is moved into
  `refunded_cents`, `retained_cents`, or `converted_cents` when it becomes
  hotel credit.

  `policy_version` is fixed when the group is opened and selects the
  cancellation window ("flex-14", "flex-30", or "advance-nonrefundable").
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :policy_version, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_cents, :integer, default: 0

    has_many :rooms, GroupStay.Groups.Room, preload_order: [asc: :position]
    has_many :credit_applications, GroupStay.Groups.CreditApplication

    timestamps()
  end
end
