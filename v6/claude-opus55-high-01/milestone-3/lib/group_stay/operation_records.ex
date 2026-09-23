defmodule GroupStay.OperationRecords do
  @moduledoc """
  Durable records of partner operations, which make `operation_id` idempotent and serve as the
  audit record of what the gateway submitted.

  Records are written by `GroupStay.PartnerOperations` in the same transaction as the domain
  changes they describe.
  """

  import Ecto.Query

  alias GroupStay.OperationRecords.OperationRecord
  alias GroupStay.Repo

  @doc "Fetches the record for `operation_id`, or `nil`."
  def get(operation_id) when is_binary(operation_id) do
    Repo.one(from r in OperationRecord, where: r.operation_id == ^operation_id)
  end

  @doc "The stored result for `operation_id`."
  def fetch_result(operation_id) when is_binary(operation_id) do
    case get(operation_id) do
      nil -> {:error, :not_found}
      record -> {:ok, result(record)}
    end
  end

  @doc "The result stored in a record, exactly as it was first returned."
  def result(%OperationRecord{result: result}), do: Jason.decode!(result)

  @doc """
  Remembers `operation`, submitted as the canonical JSON `payload`, and the `result` (decoded
  JSON) returned for it.
  """
  def insert!(operation_id, %{} = operation, payload, %{"status" => status} = result) do
    Repo.insert!(%OperationRecord{
      operation_id: operation_id,
      type: type(operation),
      payload: payload,
      result: Jason.encode!(result),
      status: status
    })

    result
  end

  @doc """
  Canonical JSON for a decoded JSON value: object keys are sorted, while array order and values
  are kept. Two submissions are equivalent when their canonical JSON is equal.
  """
  def canonical_json(value), do: value |> canonical() |> Jason.encode!()

  defp canonical(%{} = object) do
    object
    |> Enum.map(fn {key, value} -> {key, canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp type(%{"type" => type}) when is_binary(type), do: type
  defp type(_operation), do: nil
end
