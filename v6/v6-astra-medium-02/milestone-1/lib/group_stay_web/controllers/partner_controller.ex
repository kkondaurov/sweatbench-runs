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

  def ledger(conn, _params), do: json(conn, %{data: Reservations.ledger()})
end
