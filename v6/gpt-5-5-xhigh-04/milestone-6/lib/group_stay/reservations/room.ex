defmodule GroupStay.Reservations.Room do
  use Ecto.Schema

  alias GroupStay.Reservations.{CashPaymentDisposition, Group, RoomCreditAllocation}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer

    belongs_to :group, Group, foreign_key: :reservation_id
    has_many :cash_payment_dispositions, CashPaymentDisposition
    has_many :credit_allocations, RoomCreditAllocation

    timestamps(type: :utc_datetime_usec)
  end
end
