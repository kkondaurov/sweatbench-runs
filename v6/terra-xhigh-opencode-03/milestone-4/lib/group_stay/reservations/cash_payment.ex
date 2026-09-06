defmodule GroupStay.Reservations.CashPayment do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  @foreign_key_type :binary_id

  schema "cash_payments" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    belongs_to :group, Group, foreign_key: :group_db_id

    timestamps(type: :utc_datetime)
  end

  def changeset(cash_payment, attrs) do
    cash_payment
    |> cast(attrs, [
      :payment_operation_id,
      :group_db_id,
      :recorded_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_required([:payment_operation_id, :group_db_id, :recorded_cents])
    |> validate_number(:recorded_cents, greater_than: 0)
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:converted_to_credit_cents, greater_than_or_equal_to: 0)
    |> validate_number(:reduced_cents, greater_than_or_equal_to: 0)
    |> validate_number(:charged_back_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:payment_operation_id)
  end
end
