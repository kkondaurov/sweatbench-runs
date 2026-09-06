defmodule GroupStay.Groups.CashPayment do
  @moduledoc """
  A cash payment applied to a group's deposit.

  The payment's recorded cash is tracked through its dispositions: held on
  rooms, refunded, retained, converted to hotel credit, reduced by a
  provider correction, or charged back. The dispositions always sum to the
  recorded amount. Held funding can move between groups through deposit
  transfers; once any of the payment's funding has participated in a
  transfer, `transferred` remembers it.
  """

  use Ecto.Schema

  alias GroupStay.Groups.Group

  schema "cash_payments" do
    field :amount_cents, :integer
    field :occurred_on, :date
    field :operation_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transferred, :boolean, default: false

    belongs_to :group, Group

    timestamps()
  end
end
