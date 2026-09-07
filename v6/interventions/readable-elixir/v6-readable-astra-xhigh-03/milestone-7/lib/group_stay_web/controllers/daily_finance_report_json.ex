defmodule GroupStayWeb.DailyFinanceReportJSON do
  @moduledoc """
  Serializes published reports with stable JSON object ordering.

  Atom-keyed map iteration can differ between VM lifetimes. Sorting by the
  textual field name preserves the report's bytes across process restarts,
  independently of when the VM first encountered each atom.
  """

  def show(%{report: report}), do: %{data: ordered(report)}

  defp ordered(%Date{} = date), do: Date.to_iso8601(date)

  defp ordered(object) when is_map(object) do
    object
    |> Enum.map(fn {key, value} -> {to_string(key), ordered(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(values) when is_list(values), do: Enum.map(values, &ordered/1)
  defp ordered(value), do: value
end
