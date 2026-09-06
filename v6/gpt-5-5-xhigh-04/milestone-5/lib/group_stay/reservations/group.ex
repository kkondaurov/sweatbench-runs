defmodule GroupStay.Reservations.Group do
  use Ecto.Schema

  alias GroupStay.Reservations.{
    CashPaymentDisposition,
    CreditApplication,
    Room,
    RoomCreditAllocation
  }

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
    field :policy_version, :string
    field :status, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :revision, :integer

    has_many :rooms, Room, foreign_key: :reservation_id
    has_many :cash_payment_dispositions, CashPaymentDisposition, foreign_key: :reservation_id
    has_many :credit_applications, CreditApplication, foreign_key: :reservation_id
    has_many :room_credit_allocations, RoomCreditAllocation, foreign_key: :reservation_id

    timestamps(type: :utc_datetime_usec)
  end
end
