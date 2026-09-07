defmodule GroupStay.Operations do
  @moduledoc """
  Processes partner batches and durably remembers each identifiable operation.

  Each operation uses an immediate SQLite transaction: the write reservation is
  acquired before looking up the identifier, so concurrent submissions cannot
  both apply it. Its domain changes and audit record commit together. A handled
  rejection rolls back to a savepoint before its result is recorded; an exception
  rolls back the whole operation and propagates, leaving earlier commits intact.

  Results use JSON values and string keys on both the initial attempt and replay.
  Only operations with a nonempty string identifier can be remembered.
  """

  import Ecto.Query

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.Reporting
  alias GroupStay.Operations.Record
  alias GroupStay.Reservations.Operation

  @doc "Processes operations in array order, returning their original JSON results."
  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &execute/1)
  end

  @doc "Returns only the stored result, or nil when the identifier has not been remembered."
  def get_result(operation_id) do
    Repo.one(
      from record in Record, where: record.operation_id == ^operation_id, select: record.result
    )
  end

  defp execute(%{"operation_id" => id} = params) when is_binary(id) and byte_size(id) > 0 do
    {:ok, result} =
      Repo.transaction(
        fn ->
          case Repo.get_by(Record, operation_id: id) do
            nil -> apply_and_record(params)
            %Record{payload: payload, result: result} when payload === params -> result
            %Record{} -> params |> Operation.rejected("operation_id_conflict") |> json_value()
          end
        end,
        mode: :immediate
      )

    result
  end

  defp execute(params), do: params |> Operation.rejected("invalid_operation") |> json_value()

  defp apply_and_record(params) do
    # A nested Repo.transaction does not provide an independently rollbackable
    # transaction. This savepoint preserves the outer transaction's audit write.
    Repo.query!("SAVEPOINT partner_operation")

    result =
      with {:ok, operation} <- Operation.parse(params),
           {:ok, fields} <- apply_operation(operation) do
        Operation.applied(operation, fields)
      else
        {:error, error} ->
          Repo.query!("ROLLBACK TO SAVEPOINT partner_operation")
          Operation.rejected(params, error)
      end

    Repo.query!("RELEASE SAVEPOINT partner_operation")
    result = json_value(result)

    Repo.insert!(%Record{
      operation_id: params["operation_id"],
      operation_type: if(is_binary(params["type"]), do: params["type"]),
      payload: params,
      result: result
    })

    result
  end

  # Normalize dates and map keys before returning or persisting a result, so
  # replay has exactly the same representation as the original response.
  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp apply_operation(%Operation{type: "start_finance_reporting"} = operation),
    do: Reporting.start(operation)

  defp apply_operation(operation), do: Reservations.apply_operation(operation)
end
