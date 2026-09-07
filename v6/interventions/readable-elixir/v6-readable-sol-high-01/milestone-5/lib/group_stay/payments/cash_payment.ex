defmodule GroupStay.Payments.CashPayment do
  @moduledoc """
  The current disposition of one durably applied cash payment.

  Disposition amounts always partition `recorded_cents`. Settlements and
  provider corrections reclassify that original amount; they never rewrite
  the immutable partner-operation result.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Payments.{CashAllocation, CashPaymentGroupDisposition}
  alias GroupStay.Reservations.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_payments" do
    field :payment_operation_id, :string
    field :funding_order, :integer
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transfer_participated, :boolean, default: false

    belongs_to :group, Group, foreign_key: :group_record_id
    has_many :allocations, CashAllocation
    has_many :group_dispositions, CashPaymentGroupDisposition

    timestamps(type: :utc_datetime)
  end

  @fields ~w(
    payment_operation_id group_record_id funding_order recorded_cents held_cents refunded_cents
    retained_cents converted_to_credit_cents reduced_cents charged_back_cents
    transfer_participated
  )a

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:payment_operation_id)
    |> validate_number(:recorded_cents, greater_than: 0)
    |> validate_number(:held_cents, greater_than_or_equal_to: 0)
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:converted_to_credit_cents, greater_than_or_equal_to: 0)
    |> validate_number(:reduced_cents, greater_than_or_equal_to: 0)
    |> validate_number(:charged_back_cents, greater_than_or_equal_to: 0)
    |> validate_disposition_partition()
  end

  defp validate_disposition_partition(changeset) do
    fields = ~w(
      held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents
      charged_back_cents
    )a

    disposition_total = Enum.reduce(fields, 0, &(get_field(changeset, &1, 0) + &2))

    if disposition_total == get_field(changeset, :recorded_cents) do
      changeset
    else
      add_error(changeset, :recorded_cents, "must equal the sum of its dispositions")
    end
  end
end
