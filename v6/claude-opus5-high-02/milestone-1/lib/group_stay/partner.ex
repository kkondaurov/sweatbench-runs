defmodule GroupStay.Partner do
  @moduledoc """
  The partner gateway boundary: batches of operations in, one result per operation out.
  """

  alias GroupStay.Partner.Operation
  alias GroupStay.Reservations

  @doc """
  Extracts the operations from a submitted batch body.

  Returns `{:ok, operations}` for a batch carrying an operations array, `:error` otherwise.
  """
  def fetch_operations(%{"operations" => operations}) when is_list(operations),
    do: {:ok, operations}

  def fetch_operations(_body), do: :error

  @doc """
  Applies raw operations in order and returns one result per operation, in the same order.

  Operations are applied one at a time: an operation observes everything earlier operations in the
  batch changed, and a rejected operation neither undoes earlier work nor stops later operations.
  """
  def process(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  defp process_operation(raw) do
    case Operation.parse(raw) do
      {:ok, operation} ->
        operation
        |> Reservations.apply_operation()
        |> to_result(operation.operation_id)

      {:error, code} ->
        rejected(Operation.operation_id(raw), code, %{})
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
end
