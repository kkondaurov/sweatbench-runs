defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits
  alias GroupStay.Operations

  action_fallback GroupStayWeb.FallbackController

  def create(conn, params) do
    case operations(params) do
      {:ok, operations} ->
        results = Enum.map(operations, &run_operation/1)
        json(conn, %{results: results})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch"}})
    end
  end

  defp operations(params) when is_map(params) do
    operations = fetch(params, "operations")

    if is_list(operations), do: {:ok, operations}, else: :error
  end

  defp operations(_params), do: :error

  defp run_operation(raw) do
    operation_id = fetch(raw, "operation_id")

    case Operations.parse(raw) do
      {:ok, op} ->
        case Deposits.apply(op) do
          {:ok, fields} ->
            Map.merge(
              %{operation_id: operation_id, status: "applied"},
              serialize_fields(fields)
            )

          {:error, {:stale_revision, expected, actual}} ->
            %{
              operation_id: operation_id,
              status: "rejected",
              code: "stale_revision",
              group_id: op.group_id,
              expected_revision: expected,
              actual_revision: actual
            }

          {:error, code} ->
            rejected(operation_id, code)
        end

      {:error, code} ->
        rejected(operation_id, code)
    end
  end

  defp rejected(operation_id, code) do
    %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)}
  end

  defp serialize_fields(fields) do
    Map.new(fields, fn {key, value} -> {key, serialize_value(value)} end)
  end

  defp serialize_value(%Date{} = date), do: Date.to_iso8601(date)
  defp serialize_value(value), do: value

  defp fetch(map, key) when is_map(map) and is_binary(key) do
    if Map.has_key?(map, key) do
      Map.fetch!(map, key)
    else
      atom =
        String.to_existing_atom(key)

      Map.get(map, atom)
    end
  rescue
    ArgumentError -> nil
  end

  defp fetch(_map, _key), do: nil
end
