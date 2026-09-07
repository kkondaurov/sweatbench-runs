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

  def ledger(conn, _params), do: json(conn, %{data: Reservations.ledger()})
end
