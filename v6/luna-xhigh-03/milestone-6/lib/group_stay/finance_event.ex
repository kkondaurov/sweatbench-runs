defmodule GroupStay.FinanceEvent do
  @moduledoc "An immutable finance posting produced by an applied partner operation."

  use Ecto.Schema

  @primary_key {:operation_id, :string, autogenerate: false}

  schema "finance_events" do
    field :posting_on, :date
    field :cash_movements_json, :string
    field :credit_movements_json, :string
    field :credit_lot_changes_json, :string
  end
end
