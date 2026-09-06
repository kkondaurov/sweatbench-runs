defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  def create(conn, _params) do
    case operations(conn.body_params) do
      {:ok, operations} ->
        json(conn, %{results: GroupStay.Operations.apply_batch(operations)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch"}})
    end
  end

  defp operations(%{"operations" => operations}) when is_list(operations), do: {:ok, operations}
  defp operations(_body), do: :error
end
