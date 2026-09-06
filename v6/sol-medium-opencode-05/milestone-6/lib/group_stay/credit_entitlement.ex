defmodule GroupStay.CreditEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_entitlements" do
    belongs_to :lot, GroupStay.CreditLot
    belongs_to :funding, GroupStay.Funding
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:lot_id, :funding_id, :principal_cents, :entitlement_cents])
    |> validate_required([:lot_id, :funding_id, :principal_cents, :entitlement_cents])
  end
end
