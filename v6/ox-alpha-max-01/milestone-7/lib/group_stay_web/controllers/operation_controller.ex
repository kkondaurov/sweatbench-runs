defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations.Record

  @moduledoc """
  Serves the stored result of a durably remembered partner operation: the
  exact outcome of its first attempt. Only the stored result is exposed,
  never the retained submission or commit order.
  """

  def show(conn, %{"operation_id" => operation_id}) do
    case Record.fetch(operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "operation_not_found"}})

      record ->
        json(conn, %{"data" => Record.stored_result(record)})
    end
  end
end
