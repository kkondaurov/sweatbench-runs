defmodule GroupStay.Bookings.FinanceMovement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :scope, :string
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [
      :operation_id,
      :posting_on,
      :scope,
      :property_id,
      :classification,
      :amount_cents,
      :late_adjustment
    ])
    |> validate_required([
      :operation_id,
      :posting_on,
      :scope,
      :classification,
      :amount_cents,
      :late_adjustment
    ])
  end
end
