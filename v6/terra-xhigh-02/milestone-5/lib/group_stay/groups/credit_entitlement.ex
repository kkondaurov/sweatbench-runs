defmodule GroupStay.Groups.CreditEntitlement do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.CreditLot

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_entitlements" do
    belongs_to :credit_lot, CreditLot
    field :payment_operation_id, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:credit_lot_id, :payment_operation_id, :amount_cents])
    |> validate_required([:credit_lot_id, :payment_operation_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
