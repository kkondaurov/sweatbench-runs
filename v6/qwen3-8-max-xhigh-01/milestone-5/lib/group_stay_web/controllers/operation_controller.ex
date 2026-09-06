defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"operation_id" => operation_id}) do
    case Operations.recorded_result(operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      result ->
        json(conn, %{data: result})
    end
  end
end
