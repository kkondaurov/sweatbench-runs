defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.Reservations

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Reservations.batch(operations)})
  end

  def create(conn, _), do: conn |> put_status(422) |> json(%{error: %{code: "invalid_batch"}})

  def show(conn, %{"group_id" => id}) do
    case Reservations.get_group(id) do
      nil -> conn |> put_status(404) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: group})
    end
  end

  def operation(conn, %{"operation_id" => id}) do
    case Reservations.get_operation(id) do
      nil -> conn |> put_status(404) |> json(%{error: %{code: "operation_not_found"}})
      result -> json(conn, %{data: result})
    end
  end

  def payment(conn, %{"payment_operation_id" => id}) do
    case Reservations.get_payment(id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      {:error, code} ->
        status = if code == "operation_not_found", do: 404, else: 422
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end

  def daily_report(conn, params) do
    case GroupStay.FinanceReporting.daily(params["date"]) do
      {:ok, report} ->
        json(conn, %{data: stable_report(report)})

      {:error, code} ->
        status = if code == "report_not_available", do: 404, else: 422
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end

  # Atom-key map iteration can differ between BEAM instances. Published reports
  # use explicit string-key ordering to keep their JSON bytes stable on restart.
  defp stable_report(%Date{} = date), do: date

  defp stable_report(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), stable_report(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp stable_report(value) when is_list(value), do: Enum.map(value, &stable_report/1)
  defp stable_report(value), do: value

  def ledger(conn, params), do: dated_read(conn, params, &Reservations.ledger/1)

  def credit(conn, %{"guest_id" => id} = params) do
    dated_read(conn, params, &Reservations.guest_credit(id, &1))
  end

  defp dated_read(conn, params, read) do
    date =
      case Map.fetch(params, "on") do
        :error -> {:ok, Date.utc_today()}
        {:ok, value} when is_binary(value) -> Date.from_iso8601(value)
        _ -> {:error, :invalid_date}
      end

    case date do
      {:ok, on} -> json(conn, %{data: read.(on)})
      _ -> conn |> put_status(422) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
