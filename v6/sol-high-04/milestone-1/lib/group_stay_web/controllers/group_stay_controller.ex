defmodule GroupStayWeb.GroupStayController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def submit_batch(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Operations.process_batch(operations)})
  end

  def submit_batch(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end

  def show_group(conn, %{"group_id" => group_id}) do
    case Operations.get_group(group_id) do
      {:ok, group} ->
        json(conn, %{data: Operations.group_view(group)})

      {:error, :group_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end

  def ledger(conn, _params), do: json(conn, %{data: Operations.ledger_view()})
end
