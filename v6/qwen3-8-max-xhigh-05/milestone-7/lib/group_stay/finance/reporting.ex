defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  The durable finance-reporting inception point.

  The first applied `start_finance_reporting` operation creates this row. The
  financial state immediately before that operation is processed becomes the
  opening position on `starts_on`; operations processed afterward post their
  finance effects to the later of their `occurred_on` and `starts_on`, moved
  to the day after `latest_close_on` when that date falls inside a closed
  period.

  `latest_close_on` is the cutoff of the latest applied
  `close_finance_period` operation, or nil while no period has been closed.
  Reports through the cutoff are closed; later reports stay open.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_reporting" do
    field :starts_on, :date
    field :start_operation_id, :string
    field :latest_close_on, :date
    field :singleton, :integer, default: 1

    timestamps(type: :utc_datetime)
  end
end
