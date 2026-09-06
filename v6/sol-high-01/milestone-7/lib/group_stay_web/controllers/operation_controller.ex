defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Bookings

  def show(conn, %{"operation_id" => operation_id}) do
    case Bookings.get_operation(operation_id) do
      {:ok, result} ->
        json(conn, %{data: result})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})
    end
  end
end
