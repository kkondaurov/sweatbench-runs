defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  @doc """
  Returns the stored result of a remembered operation, or `404` with
  `operation_not_found`. Only the stored result is exposed.
  """
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
