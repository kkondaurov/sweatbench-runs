defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, params) do
    if is_map(params) do
      case Map.fetch(params, "operations") do
        {:ok, operations} when is_list(operations) ->
          {:ok, results} = Operations.submit_batch(operations)
          json(conn, %{results: results})

        _ ->
          invalid_batch(conn)
      end
    else
      invalid_batch(conn)
    end
  end

  defp invalid_batch(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end
end
