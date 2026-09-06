defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  @doc """
  Applies a batch of partner operations in array order and returns one
  result per operation, in the same order. A rejected operation does not
  undo earlier successful operations and does not stop later ones.
  """
  def create(conn, %{"operations" => operations}) when is_list(operations) do
    results = Enum.map(operations, &Operations.apply_operation/1)
    json(conn, %{results: results})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end
end
