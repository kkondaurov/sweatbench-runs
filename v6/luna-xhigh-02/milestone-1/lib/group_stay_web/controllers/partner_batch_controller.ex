defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, params) when is_map(params) do
    case Map.fetch(params, "operations") do
      {:ok, operations} when is_list(operations) ->
        json(conn, %{results: Enum.map(operations, &Operations.process/1)})

      _missing_or_invalid ->
        invalid_batch(conn)
    end
  end

  def create(conn, _params), do: invalid_batch(conn)

  defp invalid_batch(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end
end
