defmodule GroupStay.Payments.CashPaymentGroupDisposition do
  @moduledoc """
  Tracks where a payment's settled cash is currently classified.

  A payment can fund several groups after transfers. Keeping settlement by
  group lets a later chargeback remove the right group-level finance totals
  and advance every affected reservation's revision.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Payments.CashPayment
  alias GroupStay.Reservations.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_payment_group_dispositions" do
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    belongs_to :cash_payment, CashPayment
    belongs_to :group, Group, foreign_key: :group_record_id

    timestamps(type: :utc_datetime)
  end

  @fields ~w(
    cash_payment_id group_record_id refunded_cents retained_cents converted_to_credit_cents
  )a

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:converted_to_credit_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:cash_payment_id, :group_record_id])
  end
end
