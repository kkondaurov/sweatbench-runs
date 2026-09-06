defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.OperationalCore

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: OperationalCore.process_batch(operations)})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end
end
