defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.Reservations

  def create_batch(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Reservations.apply_batch(operations)})
  end

  def create_batch(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})
  end

  def show_group(conn, %{"group_id" => group_id}) do
    case Reservations.get_group(group_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: group})
    end
  end

  def ledger(conn, _params), do: json(conn, %{data: Reservations.ledger()})
end
