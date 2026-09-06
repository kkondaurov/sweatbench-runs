defmodule GroupStay.CreditLotContribution do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.CreditLot

  schema "credit_lot_contributions" do
    field :payment_operation_id, :string
    field :converted_cents, :integer
    field :entitlement_cents, :integer

    belongs_to :credit_lot, CreditLot
  end

  def changeset(contribution, attrs) do
    contribution
    |> cast(attrs, [
      :credit_lot_id,
      :payment_operation_id,
      :converted_cents,
      :entitlement_cents
    ])
    |> validate_required([:credit_lot_id, :converted_cents, :entitlement_cents])
    |> validate_number(:converted_cents, greater_than: 0)
    |> validate_number(:entitlement_cents, greater_than: 0)
  end
end
