defmodule GroupStay.CreditLotContribution do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lot_contributions" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer
  end

  def changeset(contribution, attrs) do
    cast(contribution, attrs, [
      :credit_lot_id,
      :payment_operation_id,
      :principal_cents,
      :entitlement_cents
    ])
    |> validate_required([:credit_lot_id, :principal_cents, :entitlement_cents])
  end
end
