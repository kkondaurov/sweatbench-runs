defmodule GroupStay.Reservations.CashPayment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cash_payments" do
    field :operation_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    belongs_to :group_reservation, GroupStay.Reservations.Group

    has_many :allocations, GroupStay.Reservations.CashAllocation
    has_many :credit_entitlements, GroupStay.Reservations.CreditEntitlement

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :operation_id,
      :group_reservation_id,
      :recorded_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_required([:operation_id, :group_reservation_id, :recorded_cents])
    |> unique_constraint(:operation_id)
  end
end
