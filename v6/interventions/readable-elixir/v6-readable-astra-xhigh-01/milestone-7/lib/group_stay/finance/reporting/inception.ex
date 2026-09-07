defmodule GroupStay.Finance.Reporting.Inception do
  @moduledoc """
  The single, immutable opening position captured when reporting starts.

  Balances are stored as JSON integers so company and property aggregates are
  not limited by SQLite's integer range. No earlier operation is replayed.
  """

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false, default: 1}
  schema "finance_reporting_inceptions" do
    field :starts_on, :date
    field :opening_position, :map
  end
end
