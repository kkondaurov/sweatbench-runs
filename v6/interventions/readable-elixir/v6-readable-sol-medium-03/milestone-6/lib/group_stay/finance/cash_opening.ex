defmodule GroupStay.Finance.CashOpening do
  @moduledoc false
  use Ecto.Schema

  alias GroupStay.Finance.ReportingStart

  schema "finance_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer
    belongs_to :reporting_start, ReportingStart
    timestamps(type: :utc_datetime)
  end
end
