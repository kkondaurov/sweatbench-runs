defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.Reservations

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Reservations.batch(operations)})
  end

  def create(conn, _), do: conn |> put_status(422) |> json(%{error: %{code: "invalid_batch"}})

  def show(conn, %{"group_id" => id}) do
    case Reservations.get_group(id) do
      nil -> conn |> put_status(404) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: group})
    end
  end

  def ledger(conn, _), do: json(conn, %{data: Reservations.ledger()})
end
