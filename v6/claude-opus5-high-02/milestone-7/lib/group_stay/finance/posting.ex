defmodule GroupStay.Finance.Posting do
  @moduledoc """
  The date one operation's finance effects post to, decided once when the operation commits.

  An operation posts on the later of its `occurred_on`, the date reporting started, and the first
  day of the open period. The first two are the date the operation would post to on its own; when
  the open period pushes it past that date, the movements it records are late adjustments to the
  day they land on, and the report states them apart from the day's ordinary movements.

  `date` is `nil` while reporting has not started, which is when an operation records nothing.
  """

  alias GroupStay.Finance.Posting

  @enforce_keys [:date, :late]
  defstruct [:date, :late]

  @type t :: %__MODULE__{}

  @doc """
  A posting that records nothing, used while reporting has not started.
  """
  def none, do: %Posting{date: nil, late: false}

  @doc """
  The date the effects post to, or `nil` while reporting has not started.
  """
  def date(%Posting{date: date}), do: date
end
