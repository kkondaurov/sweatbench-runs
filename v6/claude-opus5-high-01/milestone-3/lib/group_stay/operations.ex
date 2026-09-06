defmodule GroupStay.Operations do
  @moduledoc """
  What GroupStay remembers about the partner operations it has handled.

  Every operation carrying a usable `operation_id` is recorded once, applied or
  rejected, together with its type and its complete submitted content. The record
  makes a retry idempotent and doubles as Northstar's audit trail of the
  submissions the gateway made.
  """

  import Ecto.Query

  alias GroupStay.Operations.Payload
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @doc "Fetches the record for an identifier, or `:error` when it is unused."
  def fetch(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> :error
      record -> {:ok, record}
    end
  end

  @doc """
  Records the result returned for a submitted operation.

  Returns `{:error, changeset}` when the identifier was recorded concurrently;
  the original record is never replaced.
  """
  def remember(operation_id, params, result) do
    %Record{}
    |> Record.changeset(%{
      operation_id: operation_id,
      type: submitted_type(params),
      request_payload: Payload.canonical(params),
      result: result
    })
    |> Repo.insert()
  end

  @doc "True when `params` is the submission this record was created from."
  def same_request?(%Record{} = record, params),
    do: record.request_payload == Payload.canonical(params)

  @doc "The complete content submitted for a recorded operation."
  def submitted_content(%Record{} = record), do: Jason.decode!(record.request_payload)

  @doc "Every record, in the order the operations were committed."
  def in_commit_order, do: Repo.all(from r in Record, order_by: [asc: r.id])

  defp submitted_type(params) when is_map(params) do
    case Map.get(params, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end
end
