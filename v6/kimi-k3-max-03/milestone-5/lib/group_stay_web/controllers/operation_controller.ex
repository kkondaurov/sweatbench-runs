defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"operation_id" => operation_id}) do
    case Operations.get_record(operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:not_found)

      record ->
        render(conn, :show, result: Jason.decode!(record.result))
    end
  end
end
