defmodule GroupStay.Operations do
  @moduledoc """
  Stores submissions and their JSON results atomically with domain changes.

  Records are immutable. Their increasing IDs preserve first-commit order, and
  comparing decoded JSON ignores object key order while preserving arrays and
  value types. A submission without a usable identifier cannot be remembered.
  """

  alias GroupStay.Repo
  alias GroupStay.Operations.{Operation, Rejection}

  def get_result(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def run(submission, apply) do
    # Queue local writers so waiting native SQLite connections cannot occupy all
    # dirty IO schedulers. The immediate database lock also protects other nodes
    # and OS processes, from the initial lookup through the final commit.
    {:ok, result} =
      :global.trans(
        {{GroupStay.Reservations, :write}, self()},
        fn -> Repo.transaction(fn -> remember(submission, apply) end, mode: :immediate) end,
        [node()]
      )

    result
  end

  defp remember(submission, apply) do
    operation_id = if is_map(submission), do: submission["operation_id"]

    if is_binary(operation_id) and byte_size(operation_id) > 0 do
      case Repo.get_by(Operation, operation_id: operation_id) do
        nil ->
          result = apply_with_savepoint(operation_id, apply)

          Repo.insert!(%Operation{
            operation_id: operation_id,
            # Invalid non-string types are retained in full in the submission.
            type: if(is_binary(submission["type"]), do: submission["type"]),
            submission: submission,
            result: result
          })

          result

        %{submission: original, result: result} when original === submission ->
          result

        _record ->
          json_result(%{code: "operation_id_conflict"}, operation_id, "rejected")
      end
    else
      apply_with_savepoint(operation_id, apply)
    end
  end

  defp apply_with_savepoint(operation_id, apply) do
    Repo.query!("SAVEPOINT operation_domain")

    result =
      try do
        json_result(apply.(), operation_id, "applied")
      rescue
        rejection in Rejection ->
          # A domain rejection may follow partial credit consumption. Undo all
          # domain writes while keeping the outer transaction open for its audit.
          Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
          json_result(rejection.details, operation_id, "rejected")
      end

    Repo.query!("RELEASE SAVEPOINT operation_domain")
    result
  end

  defp json_result(details, operation_id, status) do
    details
    |> Map.merge(%{operation_id: operation_id, status: status})
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
