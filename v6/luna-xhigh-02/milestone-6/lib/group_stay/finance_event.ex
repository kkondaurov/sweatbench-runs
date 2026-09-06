defmodule GroupStay.FinanceEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_events" do
    field :operation_id, :string
    field :posting_on, :date
    field :cash_movements, :map
    field :credit_movements, :map
    field :credit_lot_changes, :map
  end

  def changeset(event, attrs) do
    cast(event, attrs, [
      :operation_id,
      :posting_on,
      :cash_movements,
      :credit_movements,
      :credit_lot_changes
    ])
    |> validate_required([
      :operation_id,
      :posting_on,
      :cash_movements,
      :credit_movements,
      :credit_lot_changes
    ])
  end
end
