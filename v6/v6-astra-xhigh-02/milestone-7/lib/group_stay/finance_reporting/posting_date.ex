defmodule GroupStay.FinanceReporting.PostingDate do
  @moduledoc false
  use Ecto.Type

  # The first open day can be beyond the API's four-digit ISO year range.
  # Store calendar days so SQL comparisons and Ecto loads still work there.
  def type, do: :integer
  def cast(value), do: Ecto.Type.cast(:date, value)
  def dump(%Date{} = on), do: {:ok, Date.to_gregorian_days(on)}
  def dump(_), do: :error
  def load(day) when is_integer(day), do: {:ok, Date.from_gregorian_days(day)}
  def load(_), do: :error
end
