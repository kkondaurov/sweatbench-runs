defmodule GroupStay.Groups.CashPayment do
  @moduledoc """
  A cash payment applied to a group's deposit.
  """

  use Ecto.Schema

  alias GroupStay.Groups.Group

  schema "cash_payments" do
    field :amount_cents, :integer
    field :occurred_on, :date
    field :operation_id, :string

    belongs_to :group, Group

    timestamps()
  end
end
