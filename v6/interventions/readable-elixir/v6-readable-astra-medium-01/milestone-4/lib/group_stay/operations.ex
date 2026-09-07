defmodule GroupStay.Operations do
  @moduledoc """
  Durable journal of partner submissions and their original JSON results.

  The SQLite writer lock is acquired before looking up an identifier and held
  through domain processing and journal insertion. The journal's increasing ID
  therefore records first-commit order, including handled rejections. Exceptions
  propagate and roll back both domain changes and the journal entry.

  Submissions without a usable operation identifier cannot be journaled. Other
  malformed submissions are remembered, with their complete content preserved.
  """
  alias GroupStay.Repo
  alias GroupStay.Operations.Entry

  @result_keys Map.new(
                 ~w(operation_id status code group_id revision deposit_due_cents amount_cents
                    outstanding_deposit_cents expected_revision actual_revision new_arrival_on
                    new_departure_on policy_version refundable_until refunded_cents retained_cents
                    credit_issued_cents cancelled_room_ids payment_operation_id charged_back_cents)a,
                 &{Atom.to_string(&1), &1}
               )

  def get_result(operation_id) do
    case Repo.get_by(Entry, operation_id: operation_id) do
      nil -> nil
      entry -> result_map(entry.result)
    end
  end

  def execute(submission, apply_operation) do
    {:ok, result} =
      Repo.write_transaction(fn ->
        case submission do
          %{"operation_id" => id} when is_binary(id) and byte_size(id) > 0 ->
            recall_or_apply(id, submission, apply_operation)

          _ ->
            apply_operation.()
        end
      end)

    result
  end

  defp recall_or_apply(id, submission, apply_operation) do
    case Repo.get_by(Entry, operation_id: id) do
      nil ->
        # Normalize dates and keys to their wire representation before returning
        # even the first result, so reads and retries have identical values.
        result = apply_operation.() |> Jason.encode!() |> Jason.decode!()

        Repo.insert!(%Entry{
          operation_id: id,
          type: if(is_binary(submission["type"]), do: submission["type"]),
          submission: submission,
          result: result
        })

        result_map(result)

      %Entry{submission: original, result: result} when original === submission ->
        result_map(result)

      _ ->
        %{operation_id: id, status: "rejected", code: "operation_id_conflict"}
    end
  end

  # Only the fixed result envelope uses atoms; partner-supplied nested values
  # (for example an invalid expected_revision) retain their JSON string keys.
  defp result_map(result) do
    Map.new(result, fn {key, value} -> {Map.fetch!(@result_keys, key), value} end)
  end
end
