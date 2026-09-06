defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations from a submitted batch.

  Every operation is evaluated and applied independently and in order, so an
  operation can observe changes made by earlier operations in the same batch.
  A rejected operation leaves the database untouched and never stops the
  remaining operations.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Operations.CancelGroup
  alias GroupStay.Operations.OpenGroup
  alias GroupStay.Operations.RecordCashPayment
  alias GroupStay.Operations.RescheduleGroup

  @known_types %{
    "open_group" => OpenGroup,
    "record_cash_payment" => RecordCashPayment,
    "reschedule_group" => RescheduleGroup,
    "cancel_group" => CancelGroup
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
  def process(%{"type" => type} = operation) when is_binary(type) do
    case @known_types do
      %{^type => module} -> module.apply(operation)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  def process(operation) do
    rejected(operation, "invalid_operation")
  end

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
