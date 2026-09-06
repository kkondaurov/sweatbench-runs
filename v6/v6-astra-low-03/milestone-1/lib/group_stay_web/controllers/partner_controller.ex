defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.Reservations

  def batch(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Reservations.batch(operations)})
  end

  def batch(conn, _),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})

  def show(conn, %{"group_id" => id}) do
    case Reservations.get_group(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: group})
    end
  end

  def ledger(conn, _), do: json(conn, %{data: Reservations.ledger()})
end
