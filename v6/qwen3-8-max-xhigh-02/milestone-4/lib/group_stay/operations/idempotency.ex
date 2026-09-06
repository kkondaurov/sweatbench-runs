defmodule GroupStay.Operations.Idempotency do
  @moduledoc """
  Durably idempotent processing for partner operations.

  The first operation received for an operation identifier is processed
  normally; its idempotency record and any domain changes commit in the
  same database transaction. A later operation with the same identifier and
  an equivalent payload returns the stored result without reading or
  changing current domain state. Reusing an identifier with a different
  payload is rejected with `operation_id_conflict` and does not replace the
  original record.

  Payload equivalence ignores JSON object key order; array order and
  values remain significant.

  An unexpected exception rolls the transaction back, so it is never
  remembered as an idempotent result.
  """

  alias Ecto.Changeset
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  @max_attempts 3

  @doc """
  Runs `fun` under the idempotency guard for `operation_id` and returns the
  result to report for the operation.

  `fun` runs inside the same transaction as the idempotency record and must
  return the operation's result map. It may roll the transaction back (for
  example with `:stale_group`); the whole attempt, including the record, is
  then retried against fresh state.
  """
  def process(operation_id, payload, fun, attempt \\ 1) do
    case Repo.transaction(fn -> attempt_once(operation_id, payload, fun) end) do
      {:ok, result} ->
        result

      {:error, reason}
      when reason in [:stale_group, :operation_record_conflict] and attempt < @max_attempts ->
        process(operation_id, payload, fun, attempt + 1)

      {:error, reason} ->
        raise "operation could not be applied: #{inspect(reason)}"
    end
  end

  defp attempt_once(operation_id, payload, fun) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil ->
        result = fun.()
        remember!(operation_id, payload, result)
        result

      %OperationRecord{} = record ->
        if equivalent?(record.payload, payload) do
          record.result
        else
          conflict(operation_id)
        end
    end
  end

  # A conflicting submission is reported but never stored: the original
  # record remains the durable account of this identifier.
  defp conflict(operation_id) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => "operation_id_conflict"}
  end

  defp remember!(operation_id, payload, result) do
    changeset =
      %OperationRecord{
        operation_id: operation_id,
        type: operation_type(payload),
        payload: payload,
        result: result
      }
      |> Changeset.change()
      |> Changeset.unique_constraint(:operation_id)

    case Repo.insert(changeset) do
      {:ok, _record} ->
        :ok

      # A concurrent attempt committed the record between the lookup and the
      # insert. Rolling back discards this attempt's domain changes; the
      # retry replays the committed record instead.
      {:error, _changeset} ->
        Repo.rollback(:operation_record_conflict)
    end
  end

  defp operation_type(payload) when is_map(payload) do
    case Map.get(payload, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp operation_type(_payload), do: nil

  @doc """
  Whether two submitted payloads are equivalent.

  JSON object key order is irrelevant; array order and values are
  significant, so scalars compare strictly.
  """
  def equivalent?(left, right) when is_map(left) and is_map(right) do
    map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, value} ->
        Map.has_key?(right, key) and equivalent?(value, Map.fetch!(right, key))
      end)
  end

  def equivalent?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and
      left
      |> Enum.zip(right)
      |> Enum.all?(fn {left_item, right_item} -> equivalent?(left_item, right_item) end)
  end

  def equivalent?(left, right), do: left === right
end
