defmodule GroupStay.CashPaymentDisposition do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Group

  schema "cash_payment_dispositions" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    belongs_to :group, Group
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [
      :group_id,
      :payment_operation_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_required([
      :group_id,
      :payment_operation_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_number(:recorded_cents, greater_than: 0)
    |> validate_number(:held_cents, greater_than_or_equal_to: 0)
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:converted_to_credit_cents, greater_than_or_equal_to: 0)
    |> validate_number(:reduced_cents, greater_than_or_equal_to: 0)
    |> validate_number(:charged_back_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:payment_operation_id)
  end
end
