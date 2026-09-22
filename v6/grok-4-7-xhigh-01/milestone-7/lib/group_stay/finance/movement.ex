defmodule GroupStay.Finance.Movement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_movements" do
    field :posting_on, :date
    field :property_id, :string
    field :bucket, :string
    field :kind, :string
    field :amount_cents, :integer
    field :operation_id, :string
    field :late, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [
      :posting_on,
      :property_id,
      :bucket,
      :kind,
      :amount_cents,
      :operation_id,
      :late
    ])
    |> validate_required([:posting_on, :bucket, :kind, :amount_cents, :operation_id, :late])
    |> validate_inclusion(:bucket, ["cash", "credit"])
    |> validate_number(:amount_cents, not_equal_to: 0)
  end
end
