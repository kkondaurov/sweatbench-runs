defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.Reservations

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
