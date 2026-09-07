defmodule GroupStay.Operations do
  @moduledoc """
  Durably processes partner submissions, including handled rejections.

  The operation lookup, domain effects and audit record share an immediate SQLite
  transaction. Its write lock serializes competing submissions before either reads
  state. An exact retry reads only the audit record and returns its original JSON
  result, even when the group's revision or credit balances have since changed.
  """

  import Ecto.Query

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Operations.Operation
  alias GroupStay.Reservations.Booking

  @operation_types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group)

  @doc "Returns only the stored JSON result, or nil when the identifier is unknown."
  def get_result(operation_id) do
    Repo.one(
      from operation in Operation,
        where: operation.operation_id == ^operation_id,
        select: operation.result
    )
  end

  @doc "Processes one JSON value and returns its applied or rejected JSON result."
  def process(payload) do
    operation_id = if is_map(payload), do: Map.get(payload, "operation_id")

    if Booking.identifier?(operation_id) do
      {:ok, result} =
        Repo.write_transaction(fn ->
          case Repo.get_by(Operation, operation_id: operation_id) do
            nil -> remember(payload)
            %Operation{payload: original, result: result} when original === payload -> result
            %Operation{} -> rejection(operation_id, :operation_id_conflict)
          end
        end)

      result
    else
      # Without a usable identifier there is no durable retry key.
      rejection(operation_id, :invalid_operation)
    end
  end

  defp remember(payload) do
    # Ecto flattens nested transactions. A SQL savepoint lets handled rejections
    # discard any domain writes while still committing their audit record.
    # Exceptions deliberately escape and roll back the entire operation.
    Repo.query!("SAVEPOINT operation_effects")
    outcome = apply_operation(payload)

    if match?({:error, _}, outcome) do
      Repo.query!("ROLLBACK TO SAVEPOINT operation_effects")
    end

    Repo.query!("RELEASE SAVEPOINT operation_effects")

    result = result(payload["operation_id"], outcome)
    type = if is_binary(payload["type"]), do: payload["type"]

    Repo.insert!(%Operation{
      operation_id: payload["operation_id"],
      type: type,
      payload: payload,
      result: result
    })

    result
  end

  defp apply_operation(payload) do
    if payload["type"] in @operation_types and Booking.identifier?(payload["group_id"]) do
      Reservations.apply_operation(payload)
    else
      {:error, :invalid_operation}
    end
  end

  defp result(operation_id, {:ok, details}), do: json_result(operation_id, "applied", details)

  defp result(operation_id, {:error, code}) when is_atom(code),
    do: rejection(operation_id, code)

  defp result(operation_id, {:error, details}),
    do: json_result(operation_id, "rejected", details)

  defp rejection(operation_id, code), do: json_result(operation_id, "rejected", %{code: code})

  defp json_result(operation_id, status, details) do
    # Normalize dates, atom keys and codes once, before both storage and delivery.
    # First submissions and replays therefore return identical JSON values.
    details
    |> Map.merge(%{operation_id: operation_id, status: status})
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
