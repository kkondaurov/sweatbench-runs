defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Partner

  def show(conn, %{"operation_id" => operation_id}) do
    case Partner.stored_result(operation_id) do
      {:ok, result} ->
        render(conn, :show, result: result)

      :error ->
        conn
        |> put_status(:not_found)
        |> render(:error, code: "operation_not_found")
    end
  end
end
