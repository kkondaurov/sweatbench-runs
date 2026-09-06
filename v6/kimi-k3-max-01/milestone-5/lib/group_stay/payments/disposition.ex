defmodule GroupStay.Payments.Disposition do
  @moduledoc """
  The current disposition of cash recorded by one durable cash payment.

  Every applied payment starts fully `held`; settlement, reductions, and
  chargebacks move amounts between kinds without ever rewriting the
  payment's stored result. Kinds: `held`, `refunded`, `retained`,
  `converted_to_credit`, `reduced`, and `charged_back`. The dispositions of
  a payment always sum to its recorded amount.

  `participated_in_transfer` records that cash from the payment has moved
  between groups in a deposit transfer, which adds `held_by_group` to the
  payment's statement.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @kinds ~w(held refunded retained converted_to_credit reduced charged_back)

  schema "payment_dispositions" do
    field :payment_operation_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :participated_in_transfer, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [:payment_operation_id, :kind, :amount_cents, :participated_in_transfer])
    |> validate_required([:payment_operation_id, :kind, :amount_cents])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:payment_operation_id, :kind])
  end
end
