defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    results = Enum.map(operations, &Operations.apply_operation/1)

    conn
    |> put_status(200)
    |> json(%{"results" => results})
  end

  def create(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{"error" => %{"code" => "invalid_batch"}})
  end
end
