defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Partner

  def create(conn, params) do
    case Partner.fetch_operations(params) do
      {:ok, operations} ->
        render(conn, :create, results: Partner.process(operations))

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, code: "invalid_batch")
    end
  end
end
