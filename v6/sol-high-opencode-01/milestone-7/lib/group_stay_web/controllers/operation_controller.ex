defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.OperationalCore

  def show(conn, %{"operation_id" => operation_id}) do
    case OperationalCore.get_operation(operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      result ->
        json(conn, %{data: result})
    end
  end
end
