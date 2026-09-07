defmodule GroupStay.Deposits.CashSettlement do
  @moduledoc """
  Settled cash from one payment classified at the group where it settled.

  A payment can fund several groups after transfers. Keeping this location lets
  a later chargeback reverse finance totals on the aggregates that own them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Deposits.Group

  schema "cash_settlements" do
    field :payment_operation_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0

    belongs_to :group, Group, foreign_key: :group_record_id

    timestamps(type: :utc_datetime)
  end

  @fields ~w(payment_operation_id group_record_id refunded_cents retained_cents
             converted_to_credit_cents)a

  def changeset(settlement, attrs) do
    settlement
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint([:payment_operation_id, :group_record_id])
  end
end
