defmodule GroupStay.Groups.CreditLotContribution do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CashPayment, CreditLot}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "credit_lot_contributions" do
    belongs_to :credit_lot, CreditLot, type: :binary_id
    belongs_to :cash_payment, CashPayment, type: :binary_id
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :position, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(contribution, attrs) do
    contribution
    |> cast(attrs, [
      :credit_lot_id,
      :cash_payment_id,
      :principal_cents,
      :entitlement_cents,
      :position
    ])
    |> validate_required([:credit_lot_id, :principal_cents, :entitlement_cents, :position])
    |> validate_number(:principal_cents, greater_than: 0)
    |> validate_number(:entitlement_cents, greater_than: 0)
  end
end
