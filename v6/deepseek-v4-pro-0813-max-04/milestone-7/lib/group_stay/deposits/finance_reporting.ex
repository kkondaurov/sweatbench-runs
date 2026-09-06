defmodule GroupStay.Deposits.FinanceReporting do
  use Ecto.Schema

  @moduledoc """
  The single-row durable state of finance reporting: the date reporting
  started and the company-wide credit liability observed when the first
  `start_finance_reporting` operation was applied. The opening position of
  every later report derives from this snapshot plus the movement journal.
  """

  schema "finance_reportings" do
    field :starts_on, :date
    field :opening_liability_cents, :integer

    timestamps()
  end
end
