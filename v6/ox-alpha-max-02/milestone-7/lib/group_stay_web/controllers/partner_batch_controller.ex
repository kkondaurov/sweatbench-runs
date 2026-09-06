defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, %{"operations" => operations} = _params) when is_list(operations) do
    results = Enum.map(operations, &Operations.apply/1)
    json(conn, %{results: results})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end
end
