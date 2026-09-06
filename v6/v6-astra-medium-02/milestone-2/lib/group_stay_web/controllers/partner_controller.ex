defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def create(conn, _params) do
    case conn.body_params do
      %{"operations" => operations} when is_list(operations) ->
        json(conn, %{results: Reservations.batch(operations)})

      _ ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})
    end
  end

  def show(conn, %{"group_id" => id}) do
    case Reservations.get_group(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: group})
    end
  end

  def ledger(conn, params), do: dated_read(conn, params, &Reservations.ledger/1)

  def credit(conn, %{"guest_id" => id} = params),
    do: dated_read(conn, params, &Reservations.guest_credit(id, &1))

  defp dated_read(conn, params, read) do
    value = Map.get(params, "on", Date.to_iso8601(Date.utc_today()))
    parsed = if is_binary(value), do: Date.from_iso8601(value), else: {:error, :invalid_format}

    case parsed do
      {:ok, on} -> json(conn, %{data: read.(on)})
      _ -> conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
