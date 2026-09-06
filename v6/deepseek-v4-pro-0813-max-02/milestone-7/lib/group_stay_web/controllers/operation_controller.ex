defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"operation_id" => operation_id}) do
    case Operations.fetch_result(operation_id) do
      {:ok, result} ->
        json(conn, %{data: result})

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})
    end
  end
end
