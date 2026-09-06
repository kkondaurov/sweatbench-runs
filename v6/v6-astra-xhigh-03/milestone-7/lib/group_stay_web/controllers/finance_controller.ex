defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  def daily_report(conn, params) do
    with {:ok, date} <- parse(params["date"]),
         {:ok, report} <- GroupStay.FinanceReporting.daily_report(date) do
      json(conn, %{data: ordered_json(report)})
    else
      {:error, "report_not_available"} ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "report_not_available"}})

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})
    end
  end

  defp parse(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse(_value), do: :error

  # Atom-map iteration order can vary between VMs. Published bytes must survive a restart,
  # so explicitly order JSON object keys, including the nested movement classifications.
  defp ordered_json(%Date{} = date), do: date

  defp ordered_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, value} -> {to_string(key), ordered_json(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered_json(value) when is_list(value), do: Enum.map(value, &ordered_json/1)
  defp ordered_json(value), do: value
end
