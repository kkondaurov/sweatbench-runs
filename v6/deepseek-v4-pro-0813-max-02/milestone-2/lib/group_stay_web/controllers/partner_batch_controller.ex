defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case params do
      %{"operations" => operations} when is_list(operations) ->
        {:ok, results} = Operations.process_batch(operations)
        json(conn, %{results: results})

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch"}})
    end
  end
end
