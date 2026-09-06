defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"operation_id" => operation_id}) do
    case Operations.get_result(operation_id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{"error" => %{"code" => "operation_not_found"}})

      result ->
        json(conn, %{"data" => result})
    end
  end
end
