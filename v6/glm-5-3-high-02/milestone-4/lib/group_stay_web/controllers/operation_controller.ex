defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.PartnerOperations

  def show(conn, %{"operation_id" => operation_id}) do
    case PartnerOperations.fetch(operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      operation ->
        json(conn, %{data: PartnerOperations.stored_result(operation)})
    end
  end
end
