defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"operation_id" => operation_id}) do
    case Operations.fetch_result(join_id(operation_id)) do
      {:ok, result} ->
        json(conn, %{data: result})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})
    end
  end

  defp join_id(operation_id) when is_binary(operation_id), do: operation_id
  defp join_id(operation_id) when is_list(operation_id), do: Enum.join(operation_id, "/")
end
