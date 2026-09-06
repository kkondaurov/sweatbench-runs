defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations.Journal

  action_fallback GroupStayWeb.FallbackController

  def show(conn, %{"operation_id" => operation_id}) do
    case Journal.fetch_result(operation_id) do
      nil -> {:error, :operation_not_found}
      result -> json(conn, %{data: result})
    end
  end
end
