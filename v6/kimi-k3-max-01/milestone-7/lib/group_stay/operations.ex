defmodule GroupStay.Operations do
  @moduledoc """
  Durable idempotency records for partner operations.

  Every operation first received by this release is remembered with its
  complete submitted content and the result it produced, applied or
  rejected, in the same database transaction as its domain changes. Records
  survive restarts and are never replaced: reusing an identifier with a
  different payload is a conflict, not an update.
  """

  import Ecto.Query

  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @doc """
  Fetches the remembered record for an operation identifier. Returns `nil`
  when no operation was ever received under that identifier.
  """
  def get_record(operation_id) when is_binary(operation_id) do
    Record
    |> where(operation_id: ^operation_id)
    |> Repo.one()
  end

  def get_record(_operation_id), do: nil

  @doc """
  Remembers an operation and its result. `type` is the submitted operation
  type (`nil` when the submission carried no usable one) and `operation` is
  the complete submitted content.
  """
  def insert_record!(operation_id, type, operation, result) do
    %Record{}
    |> Record.changeset(%{
      operation_id: operation_id,
      type: type,
      payload: Jason.encode!(operation),
      result: Jason.encode!(result)
    })
    |> Repo.insert!()
  end

  @doc """
  Whether a newly submitted operation is equivalent to the remembered one:
  JSON object key order is irrelevant, while array order and values remain
  significant.
  """
  def equivalent_payload?(%Record{} = record, operation) do
    Jason.decode!(record.payload) === operation
  end

  @doc """
  The remembered result, exactly as it was first returned.
  """
  def stored_result(%Record{} = record) do
    Jason.decode!(record.result)
  end
end
