defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.Reservations

  def batch(conn, %{"operations" => operations}) when is_list(operations),
    do: json(conn, %{results: Reservations.batch(operations)})

  def batch(conn, _),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})

  def group(conn, %{"group_id" => id}) do
    case Reservations.get(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: group})
    end
  end

  def operation(conn, %{"operation_id" => id}) do
    case Reservations.operation(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "operation_not_found"}})
      result -> json(conn, %{data: result})
    end
  end

  def payment(conn, %{"payment_operation_id" => id}) do
    case Reservations.payment(id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      {:error, code} ->
        conn
        |> put_status(
          if(code == "operation_not_found", do: :not_found, else: :unprocessable_entity)
        )
        |> json(%{error: %{code: code}})
    end
  end

  def daily_report(conn, params) do
    parsed = if is_binary(params["date"]), do: Date.from_iso8601(params["date"]), else: :error

    result =
      case parsed do
        {:ok, date} -> GroupStay.Finance.daily(date)
        _ -> {:error, "invalid_reporting_date"}
      end

    case result do
      {:ok, report} ->
        json(conn, %{data: report})

      {:error, code} ->
        conn
        |> put_status(if(code == "invalid_reporting_date", do: 422, else: 404))
        |> json(%{error: %{code: code}})
    end
  end

  def ledger(conn, params), do: dated_read(conn, params, &Reservations.ledger/1)

  def credit(conn, %{"guest_id" => id} = params),
    do: dated_read(conn, params, &Reservations.credit(id, &1))

  defp dated_read(conn, params, read) do
    parsed =
      case Map.fetch(params, "on") do
        :error -> {:ok, Date.utc_today()}
        {:ok, value} when is_binary(value) -> Date.from_iso8601(value)
        _ -> {:error, :invalid_date}
      end

    case parsed do
      {:ok, date} -> json(conn, %{data: read.(date)})
      _ -> conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
