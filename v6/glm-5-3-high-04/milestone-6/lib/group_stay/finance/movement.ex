defmodule GroupStay.Finance.Movement do
  @moduledoc """
  One signed finance movement recorded when a partner operation is applied.

  Cash movements carry the property whose held cash moved; credit movements
  are company-wide. `amount_cents` is a signed net amount within its
  classification: a normal refund reports a positive `refunded` amount, and
  reversing an earlier refund on a chargeback reports a negative `refunded`
  amount together with a positive `charged_back` amount.

  Movements are recorded from this release onward, including for operations
  processed before reporting starts: those earlier movements are excluded
  from every report (they are part of the opening position) but keep the
  per-property attribution of each payment's settled cash so a later
  chargeback can reverse a disposition at the property where it settled.

  `payment_operation_id` attributes a movement to the cash payment whose
  cash moved, when it is known. `credit_lot_id` ties `issued` and `revoked`
  credit movements to their lot.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_movements" do
    field :posted_on, :date
    field :kind, :string
    field :classification, :string
    field :amount_cents, :integer
    field :property_id, :string
    field :operation_id, :string
    field :payment_operation_id, :string
    field :credit_lot_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(movement, attrs) do
    movement
    |> Ecto.Changeset.cast(attrs, [
      :posted_on,
      :kind,
      :classification,
      :amount_cents,
      :property_id,
      :operation_id,
      :payment_operation_id,
      :credit_lot_id
    ])
    |> Ecto.Changeset.validate_required([:posted_on, :kind, :classification, :amount_cents])
  end
end
