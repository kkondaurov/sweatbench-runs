defmodule GroupStay.FinanceReporting.CashOpening do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.FinanceReporting.Configuration

  schema "finance_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer
    belongs_to :configuration, Configuration

    timestamps(type: :utc_datetime)
  end
end
