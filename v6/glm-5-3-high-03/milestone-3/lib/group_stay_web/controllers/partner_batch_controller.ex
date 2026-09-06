defmodule GroupStayWeb.PartnerBatchController do
  @moduledoc """
  Receives a batch of partner operations and reports the outcome of each one.
  """

  use GroupStayWeb, :controller

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{"results" => GroupStay.Operations.run(operations)})
  end

  # A body without an operations array is an invalid batch.
  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_batch"}})
  end
end
