defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, params) do
    case Map.get(params, "operations") do
      operations when is_list(operations) ->
        {:ok, results} = Operations.apply_batch(operations)
        render(conn, :show, results: results)

      _invalid ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:invalid_batch)
    end
  end
end
