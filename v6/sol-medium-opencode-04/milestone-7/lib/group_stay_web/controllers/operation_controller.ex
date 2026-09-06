defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"operation_id" => operation_id}) do
    case Reservations.get_operation(operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "operation_not_found"}})

      operation ->
        json(conn, %{"data" => operation.result})
    end
  end
end
