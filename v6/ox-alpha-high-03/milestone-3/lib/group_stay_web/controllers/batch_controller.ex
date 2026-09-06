defmodule GroupStayWeb.BatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, params) do
    case params["operations"] do
      operations when is_list(operations) ->
        json(conn, %{"results" => Operations.apply_batch(operations)})

      _other ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_batch"}})
    end
  end
end
