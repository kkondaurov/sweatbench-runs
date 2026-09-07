defmodule GroupStay.Operations do
  @moduledoc """
  Durable partner inbox. Submission lookup, domain changes and the original JSON
  result share one immediate SQLite transaction, so competing retries cannot both
  apply. JSON maps compare without regard to key order; lists retain their order.

  A savepoint isolates domain changes from handled rejections while allowing their
  audit records to commit. Exceptions escape and roll back the entire operation.
  Submissions without a usable identifier cannot be remembered.
  """
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Operations.Record

  def get_result(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def process_batch(operations), do: Enum.map(operations, &process/1)

  defp process(operation) do
    {:ok, result} = Repo.transaction(fn -> resolve(operation) end, mode: :immediate)
    result
  end

  defp resolve(%{"operation_id" => id} = operation) when is_binary(id) do
    if String.trim(id) == "" do
      execute(operation)
    else
      case Repo.get_by(Record, operation_id: id) do
        nil ->
          result = execute(operation)

          Repo.insert!(%Record{
            operation_id: id,
            type: if(is_binary(operation["type"]), do: operation["type"]),
            submission: operation,
            result: result
          })

          result

        %Record{submission: submission, result: result} ->
          if submission === operation,
            do: result,
            else: %{
              "operation_id" => id,
              "status" => "rejected",
              "code" => "operation_id_conflict"
            }
      end
    end
  end

  defp resolve(operation), do: execute(operation)

  defp execute(operation) do
    id = if is_map(operation), do: operation["operation_id"]
    Repo.query!("SAVEPOINT domain_operation")

    result =
      case Reservations.apply(operation) do
        {:ok, fields} ->
          Map.merge(fields, %{operation_id: id, status: "applied"})

        {:error, error} ->
          Repo.query!("ROLLBACK TO SAVEPOINT domain_operation")
          fields = if is_binary(error), do: %{code: error}, else: error
          rejection(id, fields)
      end

    Repo.query!("RELEASE SAVEPOINT domain_operation")
    # Normalize dates and keys once so initial responses and persisted retries agree.
    result |> Jason.encode!() |> Jason.decode!()
  end

  defp rejection(id, fields),
    do: Map.merge(fields, %{operation_id: id, status: "rejected"})
end
