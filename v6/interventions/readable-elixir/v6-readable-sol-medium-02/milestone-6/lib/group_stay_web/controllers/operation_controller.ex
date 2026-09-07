defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.PartnerOperations

  def show(conn, %{"operation_id" => operation_id}) do
    case PartnerOperations.get_result(operation_id) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, :operation_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})
    end
  end
end
