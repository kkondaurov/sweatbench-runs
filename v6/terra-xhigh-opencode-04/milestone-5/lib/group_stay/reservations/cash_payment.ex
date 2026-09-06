defmodule GroupStay.Reservations.CashPayment do
  use Ecto.Schema

  import Ecto.Changeset

  schema "cash_payments" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :has_transferred, :boolean, default: false

    belongs_to :group, GroupStay.Reservations.Group, type: :binary_id
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [:payment_operation_id, :group_id, :recorded_cents, :has_transferred])
    |> validate_required([:payment_operation_id, :group_id, :recorded_cents, :has_transferred])
    |> unique_constraint(:payment_operation_id)
  end
end
