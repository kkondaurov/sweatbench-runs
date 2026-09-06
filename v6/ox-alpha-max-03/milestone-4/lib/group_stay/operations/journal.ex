defmodule GroupStay.Operations.Journal do
  @moduledoc """
  Durable, at-most-once execution of partner operations.

  The journal makes `operation_id` idempotent across application and database
  restarts:

  - the first operation received for an identifier runs normally and its
    exact result — applied or rejected — is committed together with any domain
    changes in a single database transaction;
  - an identical resubmission returns that stored result without reading or
    changing current domain state;
  - reusing an identifier with different content is rejected with
    `operation_id_conflict` and never replaces the original record.

  Payloads are compared through `GroupStay.Operations.Canonical`, so JSON
  object key order is irrelevant while array order and values remain
  significant.

  An unexpected exception inside `apply_fn` rolls the whole operation back,
  leaves no record behind, and propagates to abort the HTTP request with a
  server error; only handled rejections are remembered.
  """

  alias GroupStay.Repo
  alias GroupStay.Operations.Canonical
  alias GroupStay.Operations.Record

  @conflict_code "operation_id_conflict"

  @doc """
  Runs `apply_fn` at most once for the operation identifier in `raw`.

  `apply_fn` must return `{result, type}` where `result` is the response map
  reported to the partner and `type` is the submitted operation type to retain
  for audit. Returns the result map.
  """
  @spec execute(term(), (-> {map(), String.t() | nil})) :: map()
  def execute(raw, apply_fn) when is_function(apply_fn, 0) do
    case operation_id(raw) do
      nil ->
        # Without a usable identifier there is nothing to key idempotency on;
        # the operation simply runs as before.
        {result, _type} = apply_fn.()
        result

      operation_id ->
        execute_once(raw, apply_fn, operation_id)
    end
  end

  @doc """
  The stored result first returned for `operation_id`, or nil.
  """
  @spec fetch_result(String.t()) :: map() | nil
  def fetch_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      record -> decode_result(record)
    end
  end

  defp execute_once(raw, apply_fn, operation_id, retried \\ false) do
    payload = Canonical.json(raw)

    Repo.transaction(fn ->
      case Repo.get_by(Record, operation_id: operation_id) do
        %Record{payload: ^payload} = record ->
          decode_result(record)

        %Record{} ->
          # A different payload under the same identifier never replaces the
          # original record.
          conflict(operation_id)

        nil ->
          remember(operation_id, payload, apply_fn)
      end
    end)
    |> case do
      {:ok, result} ->
        result

      # Another writer won the race to commit this identifier; replaying once
      # more takes the stored-result path against the winning record. The
      # single retry bounds the loop deterministically.
      {:error, :lost_insert_race} when not retried ->
        execute_once(raw, apply_fn, operation_id, true)
    end
  end

  defp remember(operation_id, payload, apply_fn) do
    {result, type} = apply_fn.()

    insert =
      Record.changeset(%Record{}, %{
        operation_id: operation_id,
        type: type,
        payload: payload,
        result: Jason.encode!(result)
      })
      |> Repo.insert()

    case insert do
      {:ok, _record} ->
        result

      {:error, changeset} ->
        if lost_insert_race?(changeset) do
          # Concurrent retries of one identifier are at-most-once: this
          # attempt's partial work rolls back and the winner's record replays.
          Repo.rollback(:lost_insert_race)
        else
          raise ArgumentError, "unexpected changeset error recording #{operation_id}"
        end
    end
  end

  @doc false
  # True when the changeset carries the operation_id unique-index violation
  # raised by a concurrent commit of the same identifier.
  def lost_insert_race?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:operation_id, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  defp decode_result(record), do: Jason.decode!(record.result)

  defp conflict(operation_id) do
    %{operation_id: operation_id, status: "rejected", code: @conflict_code}
  end

  defp operation_id(raw) when is_map(raw) do
    case Map.fetch(raw, "operation_id") do
      {:ok, value} -> usable_id(value)
      :error -> usable_id(Map.get(raw, :operation_id))
    end
  end

  defp operation_id(_raw), do: nil

  defp usable_id(value) when is_binary(value) and value != "", do: value
  defp usable_id(_value), do: nil
end
