defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Bookings

  def show(conn, %{"operation_id" => operation_id}) do
    case Bookings.get_operation_result(operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      result ->
        json(conn, %{data: result})
    end
  end
end
