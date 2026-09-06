defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  def create(conn, params) do
    case Map.get(params, "operations") do
      operations when is_list(operations) ->
        json(conn, %{results: GroupStay.Operations.process_batch(operations)})

      _other ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch"}})
    end
  end
end
