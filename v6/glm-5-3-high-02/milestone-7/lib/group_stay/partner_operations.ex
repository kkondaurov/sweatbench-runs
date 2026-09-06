defmodule GroupStay.PartnerOperations do
  @moduledoc """
  Durable idempotency and audit records for partner operations.

  The partner gateway retries whenever it loses a response, so the first
  result computed for an `operation_id` is retained and replayed verbatim
  on later submissions of equivalent content. Records live in the
  database — committed in the same transaction as the domain changes they
  describe — and therefore survive application and database-process
  restarts. They double as Northstar's audit record of what the gateway
  submitted.
  """

  import Ecto.Query

  alias GroupStay.PartnerOperations.Operation
  alias GroupStay.Repo

  @doc "The durable record for `operation_id`, or nil when none exists."
  def fetch(operation_id) when is_binary(operation_id) do
    Repo.one(from o in Operation, where: o.operation_id == ^operation_id)
  end

  @doc "The stored result of a remembered operation, exactly as first returned."
  def stored_result(%Operation{} = operation), do: Jason.decode!(operation.result)

  @doc """
  Persists the durable record of a first-received operation: identifier,
  submitted type, complete submitted content, and the result returned for
  it.
  """
  def record!(attrs) do
    %Operation{}
    |> Operation.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "All durable records in the order they were first committed."
  def audit_trail do
    Repo.all(from o in Operation, order_by: o.id)
  end

  @doc """
  Canonical JSON text for a submitted operation.

  Object members are sorted recursively, so key order is insignificant;
  array order and every value are preserved exactly. Two submissions with
  the same canonical text are equivalent payloads.
  """
  def canonical_json(term) when is_map(term) do
    "{" <>
      Enum.map_join(Enum.sort(Map.keys(term)), ",", fn key ->
        canonical_json(key) <> ":" <> canonical_json(Map.fetch!(term, key))
      end) <>
      "}"
  end

  def canonical_json(term) when is_list(term),
    do: "[" <> Enum.map_join(term, ",", &canonical_json/1) <> "]"

  def canonical_json(term) when is_binary(term), do: Jason.encode!(term)
  def canonical_json(term) when is_integer(term), do: Integer.to_string(term)
  def canonical_json(term) when is_float(term), do: Jason.encode!(term)
  def canonical_json(true), do: "true"
  def canonical_json(false), do: "false"
  def canonical_json(nil), do: "null"
end
