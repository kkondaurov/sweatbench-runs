defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    results = Enum.map(operations, &process_operation/1)
    json(conn, %{"results" => results})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_batch"}})
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    case Operations.apply(operation) do
      {:ok, fields} ->
        Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)

      {:error, fields} ->
        Map.merge(%{"operation_id" => operation_id, "status" => "rejected"}, fields)
    end
  end

  defp process_operation(_operation) do
    %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
  end
end
