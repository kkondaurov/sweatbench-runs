defmodule GroupStay.FinanceReporting do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash_json, :string
    field :opening_cash_details_json, :string
    field :opening_credit_cents, :integer
    field :opening_credit_lots_json, :string
  end
end
