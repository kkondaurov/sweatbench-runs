defmodule GroupStay.Reservations.FinanceReportingCashOpening do
  @moduledoc false

  use Ecto.Schema

  schema "finance_reporting_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer

    belongs_to :finance_reporting, GroupStay.Reservations.FinanceReporting

    timestamps(type: :utc_datetime)
  end
end
