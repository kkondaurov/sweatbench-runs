defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def create(%{body_params: %{"operations" => operations}} = conn, _params)
      when is_list(operations) do
    json(conn, %{results: Reservations.submit(operations)})
  end

  def create(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})
  end

  def show(conn, %{"group_id" => group_id}) do
    case Reservations.get_group(group_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: group})
    end
  end

  def daily_report(conn, params) do
    case GroupStay.FinanceReporting.daily_report(params["date"]) do
      {:ok, report} ->
        json(conn, %{data: report})

      {:error, code} ->
        status = if code == "invalid_reporting_date", do: :unprocessable_entity, else: :not_found
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end

  def ledger(conn, params) do
    with_read_date(conn, params, &Reservations.ledger/1)
  end

  def operation(conn, %{"operation_id" => operation_id}) do
    case Reservations.get_operation(operation_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "operation_not_found"}})
      result -> json(conn, %{data: result})
    end
  end

  def payment(conn, %{"payment_operation_id" => payment_id}) do
    case Reservations.get_payment(payment_id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      {:error, code} ->
        status = if code == "operation_not_found", do: :not_found, else: :unprocessable_entity
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end

  def credit(conn, %{"guest_id" => guest_id} = params) do
    with_read_date(conn, params, &Reservations.guest_credit(guest_id, &1))
  end

  defp with_read_date(conn, params, read) do
    parsed =
      case Map.fetch(params, "on") do
        :error -> {:ok, Date.utc_today()}
        {:ok, value} when is_binary(value) -> Date.from_iso8601(value)
        _ -> {:error, :invalid_date}
      end

    case parsed do
      {:ok, on} ->
        json(conn, %{data: read.(on)})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
