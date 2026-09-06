defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, %{"operations" => operations} = _params) when is_list(operations) do
    results = Enum.map(operations, &Operations.apply/1)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{results: results}))
  end

  def create(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(422, Jason.encode!(%{error: %{code: "invalid_batch"}}))
  end
end
