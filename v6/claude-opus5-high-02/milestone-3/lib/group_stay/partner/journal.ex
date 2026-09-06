defmodule GroupStay.Partner.Journal do
  @moduledoc """
  Reads and writes the durable records that make partner operations idempotent.

  Every function here runs inside the transaction that commits the operation, so an operation's
  record and its domain changes reach the database together or not at all.
  """

  alias GroupStay.Partner.Record
  alias GroupStay.Repo

  @doc """
  Returns the record already committed for an identifier, or `:error` when there is none.
  """
  def fetch(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> :error
      record -> {:ok, record}
    end
  end

  @doc """
  Remembers an operation: the result it returned, its type, and everything it submitted.
  """
  def remember!(operation_id, raw, payload, result) do
    Repo.insert!(%Record{
      operation_id: operation_id,
      type: submitted_type(raw),
      payload: payload,
      result: result
    })
  end

  # The submitted type is retained as it was sent, including a type this release does not know.
  # A type that is not a string at all is only recoverable from the payload.
  defp submitted_type(raw) when is_map(raw) do
    case Map.get(raw, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  @doc """
  The canonical JSON of a submitted operation, used to decide whether a retry is the same
  operation.

  Object keys are ordered, so key order carries no meaning. Everything else - the values, and the
  order of array elements - is preserved exactly as submitted.
  """
  def canonical(value), do: IO.iodata_to_binary(canonical_iodata(value))

  defp canonical_iodata(value) when is_map(value) do
    pairs =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, inner} -> [Jason.encode!(key), ?:, canonical_iodata(inner)] end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  defp canonical_iodata(value) when is_list(value),
    do: [?[, value |> Enum.map(&canonical_iodata/1) |> Enum.intersperse(?,), ?]]

  defp canonical_iodata(value), do: Jason.encode!(value)

  @doc """
  The stored form of an operation result.
  """
  def encode_result(result), do: Jason.encode!(result)

  @doc """
  A stored result, as the API reports it. Results are returned in the form they were stored in, so
  a retry is answered with exactly what the first attempt returned.
  """
  def decode_result(result) when is_binary(result), do: Jason.decode!(result)
  def decode_result(%Record{result: result}), do: decode_result(result)
end
