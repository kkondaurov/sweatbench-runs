defmodule GroupStayWeb.OperationController do
  @moduledoc """
  Reads the durable result remembered for a partner operation, as reported to
  the gateway when the operation was first committed.
  """

  use GroupStayWeb, :controller

  def show(conn, %{"operation_id" => operation_id}) do
    case GroupStay.Operations.fetch_result(operation_id) do
      {:ok, result} ->
        json(conn, %{"data" => result})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "operation_not_found"}})
    end
  end
end
