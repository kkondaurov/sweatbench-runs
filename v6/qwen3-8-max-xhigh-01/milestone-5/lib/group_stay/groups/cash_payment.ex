defmodule GroupStay.Groups.CashPayment do
  @moduledoc """
  A cash payment applied against a group's deposit.

  `has_transfers` records whether any of the payment's cash has ever
  participated in a deposit transfer, which changes the shape of its
  reconciliation statement.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_payments" do
    field :amount_cents, :integer
    field :occurred_on, :date
    field :operation_id, :string
    field :has_transfers, :boolean, default: false

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = payment, attrs) do
    payment
    |> cast(attrs, [:group_id, :amount_cents, :occurred_on, :operation_id])
    |> validate_required([:group_id, :amount_cents, :occurred_on])
  end
end
