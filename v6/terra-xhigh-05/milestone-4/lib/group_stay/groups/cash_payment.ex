defmodule GroupStay.Groups.CashPayment do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "cash_payments" do
    belongs_to :group, Group, foreign_key: :reservation_id, type: :binary_id
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :reservation_id,
      :payment_operation_id,
      :recorded_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_required([:reservation_id, :payment_operation_id, :recorded_cents])
    |> validate_number(:recorded_cents, greater_than: 0)
    |> unique_constraint(:payment_operation_id)
  end
end
