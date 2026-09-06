defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  def show(conn, %{"operation_id" => operation_id}) do
    case GroupStay.Operations.get_result(operation_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "operation_not_found"}})
      result -> json(conn, %{data: result})
    end
  end
end
