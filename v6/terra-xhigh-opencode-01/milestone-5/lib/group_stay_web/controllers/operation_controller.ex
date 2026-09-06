defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"operation_id" => operation_id}) do
    case Groups.get_operation(operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      operation ->
        json(conn, %{data: operation})
    end
  end
end
