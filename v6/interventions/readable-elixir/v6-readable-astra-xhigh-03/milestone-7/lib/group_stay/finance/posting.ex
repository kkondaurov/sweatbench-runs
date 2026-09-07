defmodule GroupStay.Finance.Posting do
  @moduledoc """
  The reporting date chosen under an operation's write lock.

  The original date includes the inception floor. Only a further shift caused
  by a close is a late adjustment. Scheduled expiry retains its natural date
  when that date is still open; corrections to a closed expiry move forward.
  Neither date is recalculated after the entry commits.
  """
  defstruct [:date, :original_date]

  def new(occurred_on, starts_on, cutoff) do
    original_date = later(occurred_on, starts_on)
    date = if cutoff, do: later(original_date, Date.add(cutoff, 1)), else: original_date
    %__MODULE__{date: date, original_date: original_date}
  end

  def on_or_after(posting, date) do
    %__MODULE__{
      date: later(posting.date, date),
      original_date: later(posting.original_date, date)
    }
  end

  def late?(posting), do: Date.compare(posting.date, posting.original_date) == :gt

  defp later(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
