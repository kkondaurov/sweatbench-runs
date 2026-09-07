defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.Reservations
  alias GroupStay.Reservations.Group

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Reservations.submit(operations)})
  end

  def create(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})
  end

  def show(conn, %{"group_id" => id}) do
    case Reservations.get_group(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: Group.public_data(group)})
    end
  end

  def operation(conn, %{"operation_id" => id}) do
    case GroupStay.Operations.get_result(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "operation_not_found"}})
      result -> json(conn, %{data: result})
    end
  end

  def ledger(conn, params) do
    dated_read(conn, params, &Reservations.ledger/1)
  end

  def credit(conn, %{"guest_id" => guest_id} = params) do
    dated_read(conn, params, &GroupStay.HotelCredit.balance(guest_id, &1))
  end

  defp dated_read(conn, params, read) do
    date =
      case Map.fetch(params, "on") do
        :error -> {:ok, Date.utc_today()}
        {:ok, value} when is_binary(value) -> Date.from_iso8601(value)
        _ -> {:error, :invalid_date}
      end

    case date do
      {:ok, on} ->
        json(conn, %{data: read.(on)})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
