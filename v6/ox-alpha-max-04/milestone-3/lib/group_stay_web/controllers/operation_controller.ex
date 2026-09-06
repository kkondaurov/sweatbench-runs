defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  @doc """
  Renders the stored result of a durably submitted operation. Only the result
  is exposed, not the retained submission or commit order.
  """
  def show(conn, %{"operation_id" => operation_id}) do
    case Operations.fetch_result(operation_id) do
      {:ok, result} ->
        json(conn, %{data: result})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})
    end
  end
end
