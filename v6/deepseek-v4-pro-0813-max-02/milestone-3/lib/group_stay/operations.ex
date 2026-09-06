defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations from a submitted batch and keeps durable
  idempotency records for them.

  Every operation is evaluated and applied independently and in order, so an
  operation can observe changes made by earlier operations in the same batch.
  A handled rejection leaves the database untouched beyond its idempotency
  record and never stops the remaining operations.

  The first operation received for an `operation_id` is processed normally and
  its outcome, whether applied or rejected, is remembered. A later operation
  with the same identifier and an equivalent payload returns the exact stored
  outcome without consulting current domain state. Reusing an identifier with
  a different payload is rejected with `operation_id_conflict` and never
  replaces the original record. Idempotency records and domain changes commit
  in the same database transaction; an unexpected exception rolls the current
  operation back and is not remembered.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Operations.ApplyHotelCredit
  alias GroupStay.Operations.CancelGroup
  alias GroupStay.Operations.OpenGroup
  alias GroupStay.Operations.RecordCashPayment
  alias GroupStay.Operations.RescheduleGroup
  alias GroupStay.Operations.Record, as: OperationRecord
  alias GroupStay.Repo

  @known_types %{
    "open_group" => OpenGroup,
    "record_cash_payment" => RecordCashPayment,
    "reschedule_group" => RescheduleGroup,
    "cancel_group" => CancelGroup,
    "apply_hotel_credit" => ApplyHotelCredit
  }

  @doc """
  Processes a list of raw operation maps, returning one result per operation
  in the same order.
  """
  @spec process_batch([map()]) :: {:ok, [map()]}
  def process_batch(operations) when is_list(operations) do
    {:ok, Enum.map(operations, &process/1)}
  end

  @spec process(term()) :: map()
  def process(operation) when is_map(operation) do
    canonical = canonicalize(operation)

    case Map.get(canonical, "operation_id") do
      operation_id when is_binary(operation_id) ->
        idempotent_process(operation_id, canonical)

      _ ->
        dispatch(canonical)
    end
  end

  def process(operation) do
    rejected(operation, "invalid_operation")
  end

  @doc """
  Fetches the stored result of a previously received operation.
  """
  @spec fetch_result(term()) :: {:ok, map()} | :not_found
  def fetch_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      %OperationRecord{result: result} -> {:ok, Jason.decode!(result)}
      nil -> :not_found
    end
  end

  def fetch_result(_operation_id), do: :not_found

  defp idempotent_process(operation_id, canonical) do
    try do
      {:ok, result} = Repo.transaction(fn -> dedupe_or_apply(operation_id, canonical) end)
      result
    rescue
      error in Ecto.ConstraintError ->
        # A concurrent submission of the same identifier won the race and
        # committed its record; behave exactly like a retry of it.
        case Repo.get_by(OperationRecord, operation_id: operation_id) do
          %OperationRecord{} = record ->
            if payload_matches?(record, canonical) do
              decode_result(record)
            else
              conflict_rejection(operation_id)
            end

          nil ->
            reraise error, __STACKTRACE__
        end
    end
  end

  defp dedupe_or_apply(operation_id, canonical) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      %OperationRecord{} = record ->
        if payload_matches?(record, canonical) do
          decode_result(record)
        else
          conflict_rejection(operation_id)
        end

      nil ->
        result = dispatch(canonical) |> canonicalize()
        _record = insert_record(operation_id, canonical, result)
        result
    end
  end

  defp dispatch(%{"type" => type} = operation) when is_binary(type) do
    case @known_types do
      %{^type => module} -> module.apply(operation)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp dispatch(operation) do
    rejected(operation, "invalid_operation")
  end

  defp insert_record(operation_id, canonical, result) do
    Repo.insert!(%OperationRecord{
      operation_id: operation_id,
      type: record_type(canonical),
      payload: Jason.encode!(canonical),
      result: Jason.encode!(result)
    })
  end

  defp record_type(%{"type" => type}) when is_binary(type), do: type
  defp record_type(_canonical), do: nil

  defp payload_matches?(record, canonical) do
    Jason.decode!(record.payload) == canonical
  end

  defp decode_result(record), do: Jason.decode!(record.result)

  defp conflict_rejection(operation_id) do
    %{
      "operation_id" => operation_id,
      "status" => "rejected",
      "code" => "operation_id_conflict"
    }
  end

  # JSON object key order is irrelevant for payload equivalence, so comparison
  # happens on a canonical form: object keys sorted recursively, array order
  # and values untouched.
  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {key, canonicalize(val)} end)
    |> Enum.sort_by(fn {key, _val} -> key end)
    |> Map.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)

  defp canonicalize(value), do: value

  @doc """
  Builds a rejected result. The operation id is echoed only when it is usable.
  """
  @spec rejected(term(), String.t(), keyword()) :: map()
  def rejected(operation, code, extra \\ []) do
    base = %{"status" => "rejected", "code" => code}
    base = maybe_put_operation_id(base, operation)
    Enum.into(extra, base)
  end

  defp maybe_put_operation_id(result, %{"operation_id" => operation_id})
       when is_binary(operation_id) do
    Map.put(result, "operation_id", operation_id)
  end

  defp maybe_put_operation_id(result, _operation), do: result

  @doc """
  Builds an applied result, echoing the operation id.
  """
  @spec applied(map(), keyword()) :: map()
  def applied(operation, fields) do
    base = %{"operation_id" => operation["operation_id"], "status" => "applied"}

    Enum.into(fields, base)
  end

  @doc """
  Requires `keys` to be present and non-nil in the operation. Returns either
  `{:ok, fields}` where `fields` is a map of atom keys, or `:invalid_operation`.
  """
  @spec require_fields(map(), [atom()]) :: {:ok, map()} | :invalid_operation
  def require_fields(operation, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(operation, Atom.to_string(key)) do
        {:ok, nil} -> {:halt, :invalid_operation}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, :invalid_operation}
      end
    end)
  end

  @doc """
  Parses an ISO 8601 calendar date string like "2026-12-10".
  """
  @spec parse_date(term()) :: {:ok, Date.t()} | :error
  def parse_date(value) when is_binary(value) do
    if String.match?(value, ~r/^\d{4}-\d{2}-\d{2}$/) do
      case Date.from_iso8601(value) do
        {:ok, date} -> {:ok, date}
        {:error, _} -> :error
      end
    else
      :error
    end
  end

  def parse_date(_value), do: :error

  @doc """
  Guards an operation addressed to `group`, resolving its existence first, then
  the optional `expected_revision` contract, then its active status.

  Returns `:ok` or `{:rejected, result}`.
  """
  @spec guard_group(map(), Group.t() | nil) :: :ok | {:rejected, map()}
  def guard_group(operation, nil) do
    {:rejected, rejected(operation, "group_not_found")}
  end

  def guard_group(operation, group) do
    cond do
      not revision_match?(operation, group) -> {:rejected, stale_rejection(operation, group)}
      group.status != "active" -> {:rejected, rejected(operation, "group_not_active")}
      true -> :ok
    end
  end

  defp revision_match?(operation, group) do
    case operation do
      %{"expected_revision" => nil} -> true
      %{"expected_revision" => expected} -> expected == group.revision
      _ -> true
    end
  end

  @doc """
  Builds the `stale_revision` rejection shown in the API document.
  """
  @spec stale_rejection(map(), Group.t()) :: map()
  def stale_rejection(operation, group) do
    rejected(operation, "stale_revision",
      group_id: group.group_id,
      expected_revision: operation["expected_revision"],
      actual_revision: group.revision
    )
  end
end
