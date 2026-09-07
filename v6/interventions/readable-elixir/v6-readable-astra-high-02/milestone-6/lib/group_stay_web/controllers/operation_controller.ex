defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"operation_id" => operation_id}) do
    case Reservations.get_operation(operation_id) do
      {:ok, result} -> json(conn, %{data: result})
      {:error, code} -> conn |> put_status(:not_found) |> json(%{error: %{code: code}})
    end
  end
end
