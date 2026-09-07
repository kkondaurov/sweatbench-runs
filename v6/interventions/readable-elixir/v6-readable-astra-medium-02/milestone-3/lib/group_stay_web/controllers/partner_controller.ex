defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.Reservations

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Reservations.submit_batch(operations)})
  end

  def create(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})
  end

  def show(conn, %{"group_id" => group_id}) do
    case Reservations.get_group(group_id) do
      {:ok, group} -> json(conn, %{data: group})
      {:error, code} -> conn |> put_status(:not_found) |> json(%{error: %{code: code}})
    end
  end

  def operation(conn, %{"operation_id" => operation_id}) do
    case GroupStay.Operations.fetch_result(operation_id) do
      {:ok, result} -> json(conn, %{data: result})
      {:error, code} -> conn |> put_status(:not_found) |> json(%{error: %{code: code}})
    end
  end

  def ledger(conn, params) do
    with_read_date(conn, params, &Reservations.ledger/1)
  end

  def credit(conn, %{"guest_id" => guest_id} = params) do
    with_read_date(conn, params, &Reservations.guest_credit(guest_id, &1))
  end

  defp with_read_date(conn, params, read) do
    date =
      case Map.fetch(params, "on") do
        :error -> {:ok, Date.utc_today()}
        {:ok, value} -> GroupStay.Reservations.Operation.date(value)
      end

    case date do
      {:ok, on} ->
        json(conn, %{data: read.(on)})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
