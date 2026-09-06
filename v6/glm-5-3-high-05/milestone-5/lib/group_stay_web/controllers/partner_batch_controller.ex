defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    results = Enum.map(operations, &Operations.apply/1)
    json(conn, %{"results" => results})
  rescue
    # An unexpected fault aborts the whole HTTP request: the failing operation
    # was rolled back and is not remembered, earlier operations in the batch
    # have committed, and the gateway may retry the batch.
    _exception ->
      conn
      |> put_status(:internal_server_error)
      |> json(%{"error" => %{"code" => "internal_error"}})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_batch"}})
  end
end
