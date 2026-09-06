defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  The durable reporting inception point: the first applied
  `start_finance_reporting` operation.

  The row stores the date reporting started and the opening position
  snapshot taken immediately before that operation was processed — the
  state of every operation already committed, even one whose `occurred_on`
  is on or after `starts_on`.
  """

  use Ecto.Schema

  schema "finance_reporting" do
    field :singleton, :boolean, default: true
    field :starts_on, :date
    field :operation_id, :string
    field :opening_position, :string

    timestamps()
  end
end
