defmodule GroupStay.Operations do
  @moduledoc """
  Parses partner operations and applies them in order, producing one result
  per operation for the partner batch endpoint.

  Operations missing the data needed to identify and apply them, and unknown
  operation types, are rejected with `invalid_operation`. Rejections never
  change stored state.
  """

  alias GroupStay.Groups

  @type result :: map()

  @doc """
  Applies a single operation map and returns its result:

      %{"operation_id" => "...", "status" => "applied" | "rejected", ...}
  """
  @spec apply_operation(term()) :: result()
  def apply_operation(operation) when is_map(operation) do
    with {:ok, operation_id} <- require_id(operation["operation_id"]),
         {:ok, type} <- require_id(operation["type"]),
         {:ok, group_id} <- require_id(operation["group_id"]),
         {:ok, occurred_on} <- require_date(operation["occurred_on"]) do
      dispatch(type, operation_id, group_id, occurred_on, operation)
    else
      {:error, :invalid_operation} ->
        rejection(identifier(operation["operation_id"]), :invalid_operation)
    end
  end

  def apply_operation(_operation), do: rejection(nil, :invalid_operation)

  ## Dispatch

  defp dispatch("open_group", operation_id, group_id, occurred_on, op) do
    with {:ok, guest_id} <- require_id(op["guest_id"]),
         {:ok, property_id} <- require_id(op["property_id"]) do
      case Groups.open_group(%{
             group_id: group_id,
             guest_id: guest_id,
             property_id: property_id,
             booked_on: occurred_on,
             arrival_on: op["arrival_on"],
             departure_on: op["departure_on"],
             rate_plan: op["rate_plan"],
             rooms: op["rooms"]
           }) do
        {:ok, result} -> applied(operation_id, result)
        {:error, code} -> rejection(operation_id, code)
      end
    else
      {:error, :invalid_operation} -> rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("record_cash_payment", operation_id, group_id, occurred_on, op) do
    case Groups.record_cash_payment(%{
           group_id: group_id,
           amount_cents: op["amount_cents"],
           occurred_on: occurred_on,
           operation_id: operation_id,
           expected_revision: op["expected_revision"]
         }) do
      {:ok, result} ->
        applied(operation_id, result)

      {:error, code} ->
        rejection(operation_id, code)

      {:stale, group_id, expected, actual} ->
        stale_rejection(operation_id, group_id, expected, actual)
    end
  end

  defp dispatch("reschedule_group", operation_id, group_id, occurred_on, op) do
    case Groups.reschedule_group(%{
           group_id: group_id,
           new_arrival_on: op["new_arrival_on"],
           occurred_on: occurred_on,
           operation_id: operation_id,
           expected_revision: op["expected_revision"]
         }) do
      {:ok, result} ->
        applied(operation_id, result)

      {:error, code} ->
        rejection(operation_id, code)

      {:stale, group_id, expected, actual} ->
        stale_rejection(operation_id, group_id, expected, actual)
    end
  end

  defp dispatch("cancel_group", operation_id, group_id, occurred_on, op) do
    refund_method = op["refund_method"]

    if refund_method in [nil, "cash", "hotel_credit"] do
      case Groups.cancel_group(%{
             group_id: group_id,
             refund_method: refund_method || "cash",
             occurred_on: occurred_on,
             operation_id: operation_id,
             expected_revision: op["expected_revision"]
           }) do
        {:ok, result} ->
          applied(operation_id, result)

        {:error, code} ->
          rejection(operation_id, code)

        {:stale, group_id, expected, actual} ->
          stale_rejection(operation_id, group_id, expected, actual)
      end
    else
      rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("apply_hotel_credit", operation_id, group_id, occurred_on, op) do
    case Groups.apply_hotel_credit(%{
           group_id: group_id,
           amount_cents: op["amount_cents"],
           occurred_on: occurred_on,
           operation_id: operation_id,
           expected_revision: op["expected_revision"]
         }) do
      {:ok, result} ->
        applied(operation_id, result)

      {:error, code} ->
        rejection(operation_id, code)

      {:stale, group_id, expected, actual} ->
        stale_rejection(operation_id, group_id, expected, actual)
    end
  end

  defp dispatch(_other, operation_id, _group_id, _occurred_on, _op) do
    rejection(operation_id, :invalid_operation)
  end

  ## Results

  defp applied(operation_id, result) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, result)
  end

  defp rejection(operation_id, code) when is_atom(code) do
    %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)}
  end

  defp stale_rejection(operation_id, group_id, expected_revision, actual_revision) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: "stale_revision",
      group_id: group_id,
      expected_revision: expected_revision,
      actual_revision: actual_revision
    }
  end

  ## Common field parsing

  defp require_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp require_id(_value), do: {:error, :invalid_operation}

  defp require_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_operation}
    end
  end

  defp require_date(_value), do: {:error, :invalid_operation}

  defp identifier(value) when is_binary(value), do: value
  defp identifier(_value), do: nil
end
