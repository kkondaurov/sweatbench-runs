defmodule GroupStay.Partner do
  @moduledoc """
  The partner gateway boundary: batches of operations in, one result per operation out.

  The gateway retries whenever it loses a response, so every operation it can name is remembered.
  An operation's durable record and its domain changes commit in one transaction, and a retry of a
  remembered operation is answered from that record alone, without reading or changing anything
  the operation would otherwise touch.
  """

  alias GroupStay.Partner.Journal
  alias GroupStay.Partner.Operation
  alias GroupStay.Repo
  alias GroupStay.Reservations

  @doc """
  Extracts the operations from a submitted batch body.

  Returns `{:ok, operations}` for a batch carrying an operations array, `:error` otherwise.
  """
  def fetch_operations(%{"operations" => operations}) when is_list(operations),
    do: {:ok, operations}

  def fetch_operations(_body), do: :error

  @doc """
  The result remembered for an operation identifier, or `:error` when none was ever committed.
  """
  def stored_result(operation_id) when is_binary(operation_id) do
    case Journal.fetch(operation_id) do
      {:ok, record} -> {:ok, Journal.decode_result(record)}
      :error -> :error
    end
  end

  @doc """
  Applies raw operations in order and returns one result per operation, in the same order.

  Operations are applied one at a time: an operation observes everything earlier operations in the
  batch changed, and a rejected operation neither undoes earlier work nor stops later operations.
  An unexpected fault is not a rejection - it aborts the batch and is never remembered.
  """
  def process(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  defp process_operation(raw) do
    case Operation.operation_id(raw) do
      # An operation that does not name itself cannot be remembered or recognised on a retry, so
      # it is only rejected.
      nil -> in_stored_form(rejected(nil, :invalid_operation, %{}))
      operation_id -> commit_operation(operation_id, raw)
    end
  end

  # The record and the operation's domain changes are one commit. The transaction takes its write
  # lock upfront, so concurrent retries of the same identifier are serialised and the group
  # revision an operation checks is still the group's revision when the operation writes.
  defp commit_operation(operation_id, raw) do
    payload = Journal.canonical(raw)

    {:ok, result} =
      Repo.transaction(
        fn ->
          case Journal.fetch(operation_id) do
            {:ok, record} -> replay(record, operation_id, payload)
            :error -> apply_and_remember(operation_id, raw, payload)
          end
        end,
        mode: :immediate
      )

    result
  end

  # A retry receives the original result verbatim, whatever current state would produce now.
  # Reusing an identifier for something else is refused, and leaves the original record standing.
  defp replay(record, operation_id, payload) do
    if record.payload == payload do
      Journal.decode_result(record)
    else
      in_stored_form(rejected(operation_id, :operation_id_conflict, %{}))
    end
  end

  defp apply_and_remember(operation_id, raw, payload) do
    result = Journal.encode_result(run(operation_id, raw))
    Journal.remember!(operation_id, raw, payload, result)
    Journal.decode_result(result)
  end

  defp run(operation_id, raw) do
    case Operation.parse(raw) do
      {:ok, operation} ->
        operation
        |> Reservations.apply_operation()
        |> to_result(operation_id)

      {:error, code} ->
        rejected(operation_id, code, %{})
    end
  end

  defp to_result({:ok, applied}, operation_id) do
    applied
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, "applied")
  end

  defp to_result({:error, code, details}, operation_id),
    do: rejected(operation_id, code, details)

  defp rejected(operation_id, code, details) do
    details
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, "rejected")
    |> Map.put(:code, Atom.to_string(code))
  end

  # Results that are never remembered still take the JSON shape a remembered result comes back
  # in, so every operation in a batch is answered the same way.
  defp in_stored_form(result), do: result |> Journal.encode_result() |> Journal.decode_result()
end
