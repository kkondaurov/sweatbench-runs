defmodule GroupStay.Finance.Movement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :scope, :string
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:operation_id, :posting_on, :scope, :property_id, :kind, :amount_cents])
    |> validate_required([:operation_id, :posting_on, :scope, :kind, :amount_cents])
    |> validate_inclusion(:scope, ["cash", "credit"])
    |> validate_number(:amount_cents, not_equal_to: 0)
  end
end
