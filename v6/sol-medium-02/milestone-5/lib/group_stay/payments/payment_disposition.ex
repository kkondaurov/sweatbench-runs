defmodule GroupStay.Payments.PaymentDisposition do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Group
  alias GroupStay.Payments.PaymentFunding

  schema "payment_dispositions" do
    belongs_to :payment_funding, PaymentFunding
    belongs_to :group, Group
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [
      :payment_funding_id,
      :group_id,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
    |> validate_required([
      :payment_funding_id,
      :group_id,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:converted_to_credit_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:payment_funding_id, :group_id])
  end
end
