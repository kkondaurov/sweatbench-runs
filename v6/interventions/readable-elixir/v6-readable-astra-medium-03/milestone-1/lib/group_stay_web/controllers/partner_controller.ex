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

  def ledger(conn, _params), do: json(conn, %{data: Reservations.ledger()})
end
