defmodule GroupStay.Operations do
  @moduledoc "Durable partner submissions and their original JSON results."
  alias GroupStay.{Operation, Repo}

  def get(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  # Called inside the writer's IMMEDIATE transaction. Lookup, domain effects and
  # the audit insert share one commit, including when another process is writing.
  def process(submission, apply) do
    operation_id = if is_map(submission), do: submission["operation_id"], else: nil

    if is_binary(operation_id) and byte_size(operation_id) > 0 do
      case Repo.get_by(Operation, operation_id: operation_id) do
        nil ->
          result = apply_with_savepoint(operation_id, apply)

          Repo.insert!(%Operation{
            operation_id: operation_id,
            type: if(is_binary(submission["type"]), do: submission["type"]),
            submission: submission,
            result: result
          })

          result_fields(result)

        %Operation{submission: ^submission, result: result} ->
          result_fields(result)

        _ ->
          %{operation_id: operation_id, status: "rejected", code: "operation_id_conflict"}
      end
    else
      # Malformed entries have no usable identifier under which to remember them.
      result_fields(apply_with_savepoint(operation_id, apply))
    end
  end

  def reject(fields), do: throw({__MODULE__, :rejected, fields})

  defp apply_with_savepoint(operation_id, apply) do
    Repo.query!("SAVEPOINT operation_domain")

    result =
      try do
        Map.merge(apply.(), %{operation_id: operation_id, status: "applied"})
      catch
        {__MODULE__, :rejected, fields} ->
          Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
          Map.merge(fields, %{operation_id: operation_id, status: "rejected"})
      end

    Repo.query!("RELEASE SAVEPOINT operation_domain")
    # Persist the wire representation, including date strings, so first responses
    # and retries have identical values. Unexpected faults escape to roll back
    # the entire transaction; they must never become remembered rejections.
    result |> Jason.encode!() |> Jason.decode!()
  end

  defp result_fields(result) do
    # Only server-defined, top-level result keys become atoms. Partner values,
    # including arbitrary stale expected_revision data, remain untouched.
    Map.new(result, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end
end
