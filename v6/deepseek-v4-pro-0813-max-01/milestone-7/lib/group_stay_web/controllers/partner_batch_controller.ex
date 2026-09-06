defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, params) do
    case params do
      %{"operations" => operations} when is_list(operations) ->
        json(conn, %{"results" => Operations.apply_all(operations)})

      _otherwise ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_batch"}})
    end
  end
end
