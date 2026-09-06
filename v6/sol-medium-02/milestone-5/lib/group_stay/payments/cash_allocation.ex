defmodule GroupStay.Payments.CashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Room
  alias GroupStay.Payments.PaymentFunding

  schema "cash_allocations" do
    belongs_to :room, Room
    belongs_to :payment_funding, PaymentFunding
    field :amount_cents, :integer
    field :position, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:room_id, :payment_funding_id, :amount_cents, :position])
    |> validate_required([:room_id, :amount_cents, :position])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end
end
