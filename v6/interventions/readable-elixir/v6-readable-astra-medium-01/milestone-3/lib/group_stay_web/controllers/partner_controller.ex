defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.Reservations
  alias GroupStay.Reservations.Group

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Reservations.submit(operations)})
  end

  def create(conn, _),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})

  def show(conn, %{"group_id" => id}) do
    case Reservations.get_group(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: Group.to_map(group)})
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

  def credit(conn, %{"guest_id" => id} = params) do
    dated_read(conn, params, &GroupStay.Credits.available(id, &1))
  end

  defp dated_read(conn, params, read) do
    with value when is_binary(value) <- Map.get(params, "on", Date.to_iso8601(Date.utc_today())),
         {:ok, on} <- Date.from_iso8601(value) do
      json(conn, %{data: read.(on)})
    else
      _ -> conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
