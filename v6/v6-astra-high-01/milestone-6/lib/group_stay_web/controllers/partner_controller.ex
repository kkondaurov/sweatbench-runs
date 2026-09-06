defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.{FinanceReporting, Operations, Payments, Reservations}

  def daily_report(conn, params) do
    case FinanceReporting.parse_date(params["date"]) do
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      date ->
        case FinanceReporting.daily(date) do
          {:ok, report} -> json(conn, %{data: report})
          {:error, status, code} -> conn |> put_status(status) |> json(%{error: %{code: code}})
        end
    end
  end

  def create(conn, _params) do
    case conn.body_params do
      %{"operations" => operations} when is_list(operations) ->
        json(conn, %{results: Reservations.submit(operations)})

      _ ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})
    end
  end

  def show(conn, %{"group_id" => group_id}) do
    case Reservations.get_group(group_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: group})
    end
  end

  def operation(conn, %{"operation_id" => operation_id}) do
    case Operations.get(operation_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "operation_not_found"}})
      result -> json(conn, %{data: result})
    end
  end

  def payment(conn, %{"payment_operation_id" => id}) do
    case Payments.statement(id) do
      {:ok, statement} -> json(conn, %{data: statement})
      {:error, status, code} -> conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end

  def ledger(conn, params) do
    with_read_date(conn, params, &Reservations.ledger/1)
  end

  def credit(conn, %{"guest_id" => guest_id} = params) do
    with_read_date(conn, params, &Reservations.guest_credit(guest_id, &1))
  end

  defp with_read_date(conn, params, read) do
    case Map.fetch(params, "on") do
      :error ->
        json(conn, %{data: read.(Date.utc_today())})

      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> json(conn, %{data: read.(date)})
          _ -> invalid_date(conn)
        end

      _ ->
        invalid_date(conn)
    end
  end

  defp invalid_date(conn),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
end
