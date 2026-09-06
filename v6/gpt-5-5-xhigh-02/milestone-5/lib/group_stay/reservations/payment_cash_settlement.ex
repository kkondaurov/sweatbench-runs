defmodule GroupStay.Reservations.PaymentCashSettlement do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "payment_cash_settlements" do
    field :payment_operation_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0

    belongs_to :group, Group, foreign_key: :group_pk_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(
    group_pk_id
    payment_operation_id
    refunded_cents
    retained_cents
    converted_to_credit_cents
  )a

  def changeset(settlement, attrs) do
    settlement
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:converted_to_credit_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:group_pk_id)
    |> unique_constraint([:payment_operation_id, :group_pk_id])
  end
end
