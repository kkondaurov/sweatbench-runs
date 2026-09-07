defmodule GroupStay.Operations do
  @moduledoc """
  Remembers partner submissions and their exact JSON outcomes atomically with
  domain changes. An immediate transaction acquires SQLite's writer lock before
  looking up the identifier, so concurrent retries cannot both execute.

  A savepoint isolates domain changes from the audit entry: handled rejections
  roll back those changes but remain durable. Exceptions escape and roll back the
  whole operation. Batch orchestration deliberately does not catch them.
  """
  alias GroupStay.Repo
  alias GroupStay.Operations.Record

  def get_result(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def execute(submission, apply_operation) do
    {:ok, result} =
      Repo.transaction(fn -> remember(submission, apply_operation) end, mode: :immediate)

    result
  end

  defp remember(%{"operation_id" => id} = submission, apply_operation)
       when is_binary(id) and byte_size(id) > 0 do
    case Repo.get_by(Record, operation_id: id) do
      nil ->
        result = run_domain(submission, id, apply_operation)
        type = submission["type"]

        Repo.insert!(%Record{
          operation_id: id,
          type: if(is_binary(type), do: type),
          submission: submission,
          result: result
        })

        result

      %Record{submission: original, result: result} ->
        if original === submission,
          do: result,
          else: %{"operation_id" => id, "status" => "rejected", "code" => "operation_id_conflict"}
    end
  end

  # Without a usable identifier there is no retry identity to reserve.
  defp remember(submission, apply_operation) do
    id = if is_map(submission), do: submission["operation_id"]
    run_domain(submission, id, apply_operation)
  end

  defp run_domain(submission, id, apply_operation) do
    Repo.query!("SAVEPOINT operation_domain")

    result =
      case apply_operation.(submission) do
        {:ok, fields} ->
          Map.put(fields, :status, "applied")

        {:error, code} ->
          reject(code, %{})

        {:error, code, fields} ->
          reject(code, fields)
      end

    Repo.query!("RELEASE SAVEPOINT operation_domain")

    # Normalize dates and map keys once, so first responses and persisted retries
    # have the same representation without decoding untrusted keys into atoms.
    result |> Map.put(:operation_id, id) |> Jason.encode!() |> Jason.decode!()
  end

  defp reject(code, fields) do
    Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
    Map.merge(fields, %{status: "rejected", code: code})
  end
end
