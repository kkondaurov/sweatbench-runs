defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.DurableOperations.OperationRecord
  alias GroupStay.Repo

  import Ecto.Query

  def show(conn, %{"operation_id" => operation_id}) do
    case Repo.one(from(r in OperationRecord, where: r.operation_id == ^operation_id)) do
      %OperationRecord{} = record ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{data: Jason.decode!(record.result_json)}))

      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: %{code: "operation_not_found"}}))
    end
  end
end
