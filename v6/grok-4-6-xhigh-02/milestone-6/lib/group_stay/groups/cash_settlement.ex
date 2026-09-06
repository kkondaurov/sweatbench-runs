defmodule GroupStay.Groups.CashSettlement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "cash_settlements" do
    field :payment_operation_id, :string
    field :property_id, :string
    field :disposition, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(settlement, attrs) do
    settlement
    |> cast(attrs, [:payment_operation_id, :property_id, :disposition, :amount_cents])
    |> validate_required([
      :payment_operation_id,
      :property_id,
      :disposition,
      :amount_cents
    ])
    |> unique_constraint([:payment_operation_id, :property_id, :disposition])
  end
end
