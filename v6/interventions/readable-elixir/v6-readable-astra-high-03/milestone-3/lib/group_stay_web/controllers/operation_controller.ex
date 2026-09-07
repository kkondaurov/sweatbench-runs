defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"operation_id" => id}) do
    case Operations.get_result(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "operation_not_found"}})
      result -> json(conn, %{data: result})
    end
  end
end
