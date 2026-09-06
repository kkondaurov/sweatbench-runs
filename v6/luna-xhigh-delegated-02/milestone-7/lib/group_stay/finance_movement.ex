defmodule GroupStay.FinanceMovement do
  @moduledoc "An immutable finance effect produced by a committed operation."

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_movements" do
    field :operation_id, :string
    field :commit_sequence, :integer
    field :original_posting_on, :date
    field :posting_on, :date
    field :category, :string
    field :movement, :string
    field :amount_cents, :integer
    field :property_id, :string
    field :payment_operation_id, :string
    field :lot_id, :integer
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [
      :operation_id,
      :commit_sequence,
      :original_posting_on,
      :posting_on,
      :category,
      :movement,
      :amount_cents,
      :property_id,
      :payment_operation_id,
      :lot_id
    ])
    |> validate_required([
      :operation_id,
      :commit_sequence,
      :original_posting_on,
      :posting_on,
      :category,
      :movement,
      :amount_cents
    ])
  end
end
