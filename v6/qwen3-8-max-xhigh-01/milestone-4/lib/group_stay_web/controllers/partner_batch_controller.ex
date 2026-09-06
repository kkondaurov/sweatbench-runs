defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, params) do
    case Map.get(params, "operations") do
      operations when is_list(operations) ->
        json(conn, %{results: Operations.submit_operations(operations)})

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch"}})
    end
  end
end
