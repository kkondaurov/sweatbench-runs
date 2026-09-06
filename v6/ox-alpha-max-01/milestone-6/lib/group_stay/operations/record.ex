defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable record of one partner operation, first received by this release
  or later.

  Every remembered operation — applied or rejected — keeps its type, its
  complete submitted content, and the exact result returned to the gateway.
  Records commit in the same transaction as their domain changes, and the
  unique index on `operation_id` keeps concurrent retries at-most-once. The
  insertion order of the rows preserves the order in which records were
  first committed, so the table doubles as Northstar's audit trail of what
  the gateway submitted.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Operations.Payload
  alias GroupStay.Repo

  schema "durable_operations" do
    field :operation_id, :string
    field :type, :string
    field :submitted_json, :string
    field :result_json, :string

    timestamps()
  end

  @doc """
  The record stored for `operation_id`, if one was ever committed.
  """
  def fetch(operation_id) do
    Repo.get_by(__MODULE__, operation_id: operation_id)
  end

  @doc """
  Every durable record in first-committed order.
  """
  def list do
    Repo.all(from(r in __MODULE__, order_by: r.id))
  end

  @doc """
  Remembers an operation's submission and its result.

  Returns `:ok`, or `{:conflict, record}` when a concurrent transaction
  already committed this `operation_id`; the caller then decides between a
  replay and an `operation_id_conflict` rejection.
  """
  def insert(operation_id, operation, result) do
    %__MODULE__{}
    |> changeset(%{
      operation_id: operation_id,
      type: type_text(operation["type"]),
      submitted_json: Payload.canonical_json(operation),
      result_json: Jason.encode!(result)
    })
    |> Repo.insert()
    |> case do
      {:ok, _record} -> :ok
      {:error, _changeset} -> {:conflict, fetch(operation_id)}
    end
  end

  @doc """
  The exact result returned for this operation on its first attempt.
  """
  def stored_result(record), do: Jason.decode!(record.result_json)

  defp changeset(record, attrs) do
    record
    |> cast(attrs, [:operation_id, :type, :submitted_json, :result_json])
    |> validate_required([:operation_id, :submitted_json, :result_json])
    |> unique_constraint(:operation_id)
  end

  defp type_text(nil), do: nil
  defp type_text(type) when is_binary(type), do: type
  defp type_text(type), do: Jason.encode!(type)
end
