defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def create(conn, params) do
    case params do
      %{"operations" => operations} when is_list(operations) ->
        results = Groups.apply_batch(operations)
        json(conn, %{results: results})

      _invalid ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch"}})
    end
  end
end
