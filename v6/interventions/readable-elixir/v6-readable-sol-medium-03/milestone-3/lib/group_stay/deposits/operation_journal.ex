defmodule GroupStay.Deposits.OperationJournal do
  @moduledoc """
  Provides durable, transactional idempotency for partner operations.

  A fresh operation's domain work runs behind a savepoint. Applied work is kept, while a handled
  rejection rolls back to the savepoint before its result is recorded. The enclosing immediate
  transaction couples the receipt to applied changes and serializes competing SQLite writers.
  """

  alias GroupStay.Deposits.OperationRecord
  alias GroupStay.Repo

  @savepoint "fresh_operation"

  @doc "Processes or replays an operation with a valid partner identifier."
  def process(operation, handler, result_formatter)
      when is_map(operation) and is_function(handler, 0) and is_function(result_formatter, 1) do
    {:ok, result} =
      Repo.transaction(
        fn -> idempotently_process(operation, handler, result_formatter) end,
        mode: :immediate
      )

    result
  end

  @doc "Returns a previously stored result without exposing its audit submission."
  def get_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, record.result}
    end
  end

  def get_result(_operation_id), do: {:error, :operation_not_found}

  defp idempotently_process(operation, handler, result_formatter) do
    operation_id = operation["operation_id"]

    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      %OperationRecord{submitted_content: submitted, result: result}
      when submitted === operation ->
        result

      %OperationRecord{} ->
        result_formatter.({:error, :operation_id_conflict})

      nil ->
        process_and_remember(operation, handler, result_formatter)
    end
  end

  defp process_and_remember(operation, handler, result_formatter) do
    Repo.query!("SAVEPOINT #{@savepoint}")
    outcome = handler.()

    case outcome do
      {:ok, _fields} ->
        Repo.query!("RELEASE SAVEPOINT #{@savepoint}")

      {:error, _reason} ->
        Repo.query!("ROLLBACK TO SAVEPOINT #{@savepoint}")
        Repo.query!("RELEASE SAVEPOINT #{@savepoint}")
    end

    stored_result = outcome |> result_formatter.() |> json_value()

    %OperationRecord{
      operation_id: operation["operation_id"],
      operation_type: operation_type(operation),
      submitted_content: operation,
      result: stored_result
    }
    |> Repo.insert!()

    stored_result
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  # Fresh and replayed results use the same string-keyed JSON representation, including when an
  # operation is repeated within one batch.
  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
