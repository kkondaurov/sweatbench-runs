defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  def create(conn, params) do
    case Map.get(params, "operations") do
      ops when is_list(ops) ->
        results = GroupStay.Batches.process_batch(ops)
        json(conn, %{results: results})

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch"}})
    end
  end
end
