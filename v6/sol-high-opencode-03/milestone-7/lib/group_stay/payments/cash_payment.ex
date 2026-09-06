defmodule GroupStay.Payments.CashPayment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:operation_id, :string, autogenerate: false}
  schema "cash_payments" do
    field :group_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transfer_participated, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :operation_id,
      :group_id,
      :recorded_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents,
      :transfer_participated
    ])
    |> validate_required([:operation_id, :group_id, :recorded_cents])
    |> validate_number(:recorded_cents, greater_than: 0)
    |> unique_constraint(:operation_id)
  end
end
