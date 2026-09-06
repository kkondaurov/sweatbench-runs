defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  The durable reporting inception point, created by the first applied
  `start_finance_reporting` operation.

  `starts_on` is the first day of the report timeline and `snapshot` holds
  the opening position captured immediately before that operation was
  processed: the held cash of every property and the balance of every credit
  lot, including every operation already committed, even one whose
  `occurred_on` is on or after `starts_on`. `start_operation_id` names the
  start operation's durable record, so the report timeline can attribute
  movements to the operations committed after it.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_reporting" do
    field :starts_on, :date
    field :start_operation_id, :string
    field :snapshot, :string

    timestamps(type: :utc_datetime)
  end
end
