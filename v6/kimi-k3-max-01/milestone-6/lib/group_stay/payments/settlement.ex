defmodule GroupStay.Payments.Settlement do
  @moduledoc """
  The settled-group attribution of a payment's settled cash.

  Every payment whose cash is settled (refunded, retained, or converted to
  credit) records here which group held the allocations at settlement time.
  A later chargeback reads the attribution so the reclassification follows
  the affected cash to the property where it settled rather than the
  payment's original group, then clears it. Attributions for cash settled
  before durable operation records cannot exist, so none is recorded for the
  unattributed senior block.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @kinds ~w(refunded retained converted_to_credit)

  schema "payment_settlements" do
    field :payment_operation_id, :string
    field :kind, :string
    field :amount_cents, :integer

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  def changeset(settlement, attrs) do
    settlement
    |> cast(attrs, [:payment_operation_id, :group_id, :kind, :amount_cents])
    |> validate_required([:payment_operation_id, :group_id, :kind, :amount_cents])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount_cents, greater_than: 0)
    |> assoc_constraint(:group)
  end
end
