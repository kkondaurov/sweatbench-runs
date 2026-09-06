defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Enum.map(operations, &Groups.apply_operation/1)})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end
end
