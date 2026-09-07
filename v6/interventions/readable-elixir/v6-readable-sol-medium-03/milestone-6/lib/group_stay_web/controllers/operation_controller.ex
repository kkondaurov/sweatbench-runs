defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, %{"operation_id" => operation_id}) do
    case Deposits.get_operation_result(operation_id) do
      {:ok, result} -> json(conn, %{data: result})
      {:error, :operation_not_found} -> not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "operation_not_found"}})
  end
end
