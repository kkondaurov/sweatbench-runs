defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  require Logger

  alias GroupStay.Operations

  @doc """
  Applies a batch of partner operations in array order and returns one
  result per operation, in the same order. A rejected operation does not
  undo earlier successful operations and does not stop later ones. An
  unexpected server fault aborts the request with `500`; the operation that
  raised is not remembered as an idempotent result.
  """
  def create(conn, %{"operations" => operations}) when is_list(operations) do
    results = Enum.map(operations, &Operations.apply_operation/1)
    json(conn, %{results: results})
  rescue
    exception ->
      Logger.error("partner batch aborted: " <> Exception.message(exception))

      conn
      |> put_status(:internal_server_error)
      |> json(%{error: %{code: "internal_error"}})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end
end
