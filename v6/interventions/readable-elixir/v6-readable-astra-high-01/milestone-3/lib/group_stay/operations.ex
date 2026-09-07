defmodule GroupStay.Operations do
  @moduledoc """
  Durable partner operation receipts and the transaction boundary for execution.

  The immediate write transaction serializes receipt lookup with domain changes
  and receipt insertion, including across application instances. A savepoint
  discards domain changes on a handled rejection while allowing its receipt to
  commit. Unexpected faults escape and roll back the entire operation.
  """
  alias GroupStay.Repo
  alias GroupStay.Operations.Record

  def get_result(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      record -> Record.original_result(record)
    end
  end

  @doc "Executes domain validation and changes at most once for an identified JSON operation."
  def execute(operation, apply_operation) do
    operation_id = if is_map(operation), do: operation["operation_id"], else: nil

    if is_binary(operation_id) and byte_size(operation_id) > 0 do
      {:ok, result} =
        Repo.write_transaction(fn ->
          case Repo.get_by(Record, operation_id: operation_id) do
            nil ->
              remember(operation, apply_operation)

            %Record{payload: payload} = record when payload === operation ->
              Record.original_result(record)

            %Record{} ->
              rejection(operation_id, "operation_id_conflict")
          end
        end)

      result
    else
      rejection(operation_id, "invalid_operation")
    end
  end

  defp remember(operation, apply_operation) do
    Repo.query!("SAVEPOINT operation_domain")

    {status, fields} =
      case apply_operation.(operation) do
        {:ok, fields} ->
          {"applied", fields}

        {:error, fields} ->
          Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
          {"rejected", fields}
      end

    Repo.query!("RELEASE SAVEPOINT operation_domain")
    result = Map.merge(fields, %{operation_id: operation["operation_id"], status: status})

    Repo.insert!(%Record{
      operation_id: operation["operation_id"],
      type: if(is_binary(operation["type"]), do: operation["type"]),
      payload: operation,
      result: result
    })

    result
  end

  defp rejection(operation_id, code),
    do: %{operation_id: operation_id, status: "rejected", code: code}
end
