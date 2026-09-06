defmodule GroupStay.CashPayment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:operation_id, :string, autogenerate: false}
  schema "cash_payment_records" do
    field :group_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer
  end

  def changeset(payment, attrs) do
    cast(payment, attrs, [
      :operation_id,
      :group_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_required([
      :operation_id,
      :group_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
  end
end
