defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits
  alias GroupStay.Operations
  alias GroupStay.Operations.Journal

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

  # The journal decides whether the operation runs now or replays a result it
  # already committed for this operation_id.
  defp run_operation(raw) do
    Journal.execute(raw, fn -> fresh_outcome(raw) end)
  end

  defp fresh_outcome(raw) do
    operation_id = fetch(raw, "operation_id")

    case Operations.parse(raw) do
      {:ok, op} ->
        outcome(op, operation_id)

      {:error, code} ->
        {rejected(operation_id, code), submitted_type(raw)}
    end
  end

  defp outcome(op, operation_id) do
    type = Atom.to_string(op.type)

    case Deposits.apply_in_transaction(op) do
      {:ok, fields} ->
        {Map.merge(
           %{operation_id: operation_id, status: "applied"},
           serialize_fields(fields)
         ), type}

      {:error, {:stale_revision, group_id, expected, actual}} ->
        {%{
           operation_id: operation_id,
           status: "rejected",
           code: "stale_revision",
           group_id: group_id,
           expected_revision: expected,
           actual_revision: actual
         }, type}

      {:error, code} ->
        {rejected(operation_id, code), type}
    end
  end

  defp rejected(operation_id, code) do
    %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)}
  end

  defp submitted_type(raw) do
    case fetch(raw, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
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
