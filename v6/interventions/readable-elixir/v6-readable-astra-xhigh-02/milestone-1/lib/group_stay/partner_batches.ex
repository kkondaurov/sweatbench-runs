defmodule GroupStay.PartnerBatches do
  @moduledoc """
  Processes partner operations in order, preserving one outcome per input value.
  Operation identifiers are correlation values supplied by the partner; they do
  not imply retries or deduplication.
  """

  alias GroupStay.Reservations
  alias GroupStay.Reservations.Booking

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group)

  def submit(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def submit(_batch), do: {:error, :invalid_batch}

  defp process_operation(operation) do
    outcome =
      if valid_envelope?(operation),
        do: Reservations.apply_operation(operation),
        else: {:error, %{code: :invalid_operation}}

    operation_id = if is_map(operation), do: Map.get(operation, "operation_id"), else: nil

    case outcome do
      {:ok, result} -> Map.merge(result, %{operation_id: operation_id, status: "applied"})
      {:error, result} -> Map.merge(result, %{operation_id: operation_id, status: "rejected"})
    end
  end

  defp valid_envelope?(operation) when is_map(operation) do
    operation["type"] in @operation_types and
      Booking.identifier?(operation["operation_id"]) and
      Booking.identifier?(operation["group_id"])
  end

  defp valid_envelope?(_operation), do: false
end
