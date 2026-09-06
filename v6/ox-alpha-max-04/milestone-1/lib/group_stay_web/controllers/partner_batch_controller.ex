defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  @doc """
  Processes the operations array in order and returns one result per
  operation. A body without an operations array is an invalid batch.
  """
  def create(conn, _params) do
    operations =
      case conn.body_params do
        %{"operations" => operations} -> operations
        _ -> nil
      end

    if is_list(operations) do
      results = Enum.map(operations, &Operations.apply_operation/1)
      json(conn, %{results: results})
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: %{code: "invalid_batch"}})
    end
  end
end
