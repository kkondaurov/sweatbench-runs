defmodule GroupStay.PartnerOperations do
  @moduledoc """
  Durably remembers partner submissions and results in the domain transaction.

  The immediate SQLite transaction serializes lookup, application, and audit
  insertion across connections. Retries only inspect the audit record.
  """

  alias GroupStay.Repo
  alias GroupStay.PartnerOperations.Operation

  def get_result(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def process(operation, apply_operation) do
    {:ok, result} =
      transact(operation, apply_operation, System.monotonic_time(:millisecond) + 5_000)

    # Keep atom field names for context callers, with JSON values on both first
    # attempts and retries (including ISO strings for dates).
    Map.new(result, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp transact(operation, apply_operation, lock_deadline) do
    Repo.transact(fn -> {:ok, remember(operation, apply_operation)} end, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      # Only a failed BEGIN is safe to retry: the operation has not started.
      if error.message == "database is locked" and
           error.statement == "BEGIN IMMEDIATE TRANSACTION" and
           System.monotonic_time(:millisecond) < lock_deadline do
        Process.sleep(10 + :rand.uniform(40))
        transact(operation, apply_operation, lock_deadline)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp remember(%{"operation_id" => id} = operation, apply_operation)
       when is_binary(id) and byte_size(id) > 0 do
    case Repo.get_by(Operation, operation_id: id) do
      nil ->
        result = run(operation, apply_operation)

        Repo.insert!(%Operation{
          operation_id: id,
          type: if(is_binary(operation["type"]), do: operation["type"]),
          payload: operation,
          result: result
        })

        result

      %Operation{payload: payload, result: result} when payload === operation ->
        result

      %Operation{} ->
        %{"operation_id" => id, "status" => "rejected", "code" => "operation_id_conflict"}
    end
  end

  # An invalid identifier cannot name an idempotency record. Preserve the normal
  # invalid_operation response and continue processing the batch.
  defp remember(operation, apply_operation), do: run(operation, apply_operation)

  defp run(operation, apply_operation) do
    # A nested Ecto transaction would roll back the audit insertion as well.
    # A savepoint isolates domain changes while allowing a rejection to commit.
    Repo.query!("SAVEPOINT partner_operation_domain")
    {outcome, fields} = apply_operation.(operation)

    if outcome == :error, do: Repo.query!("ROLLBACK TO SAVEPOINT partner_operation_domain")
    Repo.query!("RELEASE SAVEPOINT partner_operation_domain")

    fields
    |> Map.merge(%{
      operation_id: if(is_map(operation), do: operation["operation_id"]),
      status: if(outcome == :ok, do: "applied", else: "rejected")
    })
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
