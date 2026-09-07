defmodule GroupStay.Operations do
  @moduledoc """
  Durable partner submissions and their original JSON results.

  Immediate SQLite transactions serialize writers before the replay lookup. The
  generated record ID therefore orders first commits, including rejections. A
  savepoint isolates domain work so handled rejections can still be remembered;
  unexpected exceptions escape and roll back the entire transaction.
  """
  alias GroupStay.{Operations.Record, Repo}

  def get_result(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def execute(submission, apply_operation) do
    {:ok, result} =
      Repo.transaction(fn -> replay_or_apply(submission, apply_operation) end, mode: :immediate)

    result
  end

  def reject(error), do: throw({__MODULE__, :rejected, error})

  defp replay_or_apply(submission, apply_operation) do
    id = if is_map(submission), do: submission["operation_id"]
    identifiable? = is_binary(id) && byte_size(id) > 0
    record = if identifiable?, do: Repo.get_by(Record, operation_id: id)

    case record do
      %Record{submission: original, result: result} when original === submission ->
        result

      %Record{} ->
        result(%{code: "operation_id_conflict"}, id, "rejected")

      nil ->
        outcome = apply_with_savepoint(apply_operation, id)

        if identifiable? do
          Repo.insert!(%Record{
            operation_id: id,
            operation_type: if(is_binary(submission["type"]), do: submission["type"]),
            submission: submission,
            result: outcome
          })
        end

        outcome
    end
  end

  defp apply_with_savepoint(apply_operation, id) do
    Repo.query!("SAVEPOINT operation_domain")

    outcome =
      try do
        result(apply_operation.(), id, "applied")
      catch
        {__MODULE__, :rejected, error} ->
          Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
          result(error, id, "rejected")
      end

    Repo.query!("RELEASE SAVEPOINT operation_domain")
    outcome
  end

  # Normalize dates and map keys once so first responses and durable replays have
  # exactly the same JSON representation.
  defp result(fields, id, status) do
    fields
    |> Map.merge(%{operation_id: id, status: status})
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
