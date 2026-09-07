defmodule GroupStayWeb.DailyFinanceReportJSON do
  @moduledoc """
  Gives published reports a stable JSON representation across application restarts.

  Atom-keyed maps can enumerate differently in a fresh VM. Sort JSON object keys
  explicitly at the rendering boundary, retaining the report's domain array order.
  """

  def data(report), do: ordered(report)

  defp ordered(value) when is_map(value) do
    value
    |> Enum.map(fn {key, value} -> {to_string(key), ordered(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value
end
