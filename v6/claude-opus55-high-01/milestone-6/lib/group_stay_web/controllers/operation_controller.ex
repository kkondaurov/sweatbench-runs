defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.OperationRecords

  # Exposes only the stored result, not the retained submission or commit order.
  def show(conn, %{"operation_id" => operation_id}) do
    case OperationRecords.fetch_result(operation_id) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})
    end
  end
end
