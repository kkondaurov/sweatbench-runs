defmodule GroupStay.Operations do
  @moduledoc """
  Durable partner retry handling and submission auditing.

  An immediate SQLite transaction acquires the write lock before the journal is
  read. Competing submissions therefore observe the committed winner, including
  its original rejection or revision, without evaluating domain state again.
  Exceptions propagate and roll back both domain writes and the journal entry.

  Payloads are stored as complete JSON objects and compared structurally: object
  key order is irrelevant, while arrays and values are significant. Results are
  normalized to JSON on the first attempt so first responses and retries have
  the same representation, including dates and keys.

  Malformed envelopes with a usable operation ID are remembered. Submissions
  without a nonempty string ID are rejected normally but cannot be journaled.
  """
  alias GroupStay.Operations.Record
  alias GroupStay.Repo
  alias GroupStay.Reservations.Operation

  def fetch_result(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> {:error, "operation_not_found"}
      record -> {:ok, record.result}
    end
  end

  @doc "Executes a domain callback only for a previously unseen submission."
  def execute(payload, apply_operation) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          operation_id = if is_map(payload), do: payload["operation_id"]

          if Operation.identifier?(operation_id) do
            replay_or_apply(operation_id, payload, apply_operation)
          else
            json_result(apply_operation.())
          end
        end,
        mode: :immediate
      )

    result
  end

  defp replay_or_apply(operation_id, payload, apply_operation) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil ->
        result = json_result(apply_operation.())
        type = if is_binary(payload["type"]), do: payload["type"]

        Repo.insert!(%Record{
          operation_id: operation_id,
          type: type,
          payload: payload,
          result: result
        })

        result

      %Record{payload: original, result: result} when original === payload ->
        result

      %Record{} ->
        %{
          "operation_id" => operation_id,
          "status" => "rejected",
          "code" => "operation_id_conflict"
        }
    end
  end

  defp json_result(result), do: result |> Jason.encode!() |> Jason.decode!()
end
