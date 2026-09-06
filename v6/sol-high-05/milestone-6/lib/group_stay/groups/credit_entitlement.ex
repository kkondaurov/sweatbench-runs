defmodule GroupStay.Groups.CreditEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :charged_back, :boolean, default: false
    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @fields ~w(credit_lot_id payment_operation_id principal_cents entitlement_cents charged_back)a

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, @fields)
    |> validate_required([:credit_lot_id, :principal_cents, :entitlement_cents, :charged_back])
    |> validate_number(:principal_cents, greater_than: 0)
    |> validate_number(:entitlement_cents, greater_than: 0)
    |> foreign_key_constraint(:credit_lot_id)
  end
end
