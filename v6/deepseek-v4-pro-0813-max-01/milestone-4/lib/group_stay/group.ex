defmodule GroupStay.Group do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string
    field :revision, :integer
    field :deposit_paid_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :policy_version, :string
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer
    field :cash_converted_to_credit_cents, :integer
    field :cash_reduced_cents, :integer
    field :cash_charged_back_cents, :integer

    has_many :rooms, GroupStay.Room
    has_many :credit_applications, GroupStay.CreditApplication
    has_many :room_allocations, GroupStay.RoomAllocation

    timestamps()
  end
end
