defmodule GroupStay.Reservations.Operation do
  @moduledoc """
  Validates the partner operation envelope without coercing partner identifiers or money.

  Domain values are checked after resolving the group and its expected revision, so stale
  writers receive the same response regardless of the booking rule they would violate.
  """

  @required_fields %{
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "apply_hotel_credit" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => [],
    "cancel_rooms" => ~w(room_ids),
    "reduce_cash_payment" => ~w(amount_cents),
    "charge_back_payment" => [],
    "transfer_deposit" => ~w(amount_cents),
    "start_finance_reporting" => [],
    "close_finance_period" => []
  }

  def validate(operation) when is_map(operation) do
    with {:ok, fields} <- Map.fetch(@required_fields, operation["type"]),
         true <- identifier?(operation["operation_id"]),
         true <- valid_target?(operation),
         true <- Enum.all?(["occurred_on" | fields], &Map.has_key?(operation, &1)),
         true <- valid_open_identifiers?(operation) do
      :ok
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  def validate(_), do: {:error, "invalid_operation"}

  def identifier?(value), do: is_binary(value) and byte_size(value) > 0

  def date(value) when is_binary(value), do: Date.from_iso8601(value)
  def date(_), do: {:error, :invalid_format}

  defp valid_target?(%{"type" => type} = operation)
       when type in ["reduce_cash_payment", "charge_back_payment"],
       do: identifier?(operation["payment_operation_id"])

  defp valid_target?(%{"type" => "transfer_deposit"} = operation),
    do:
      identifier?(operation["source_group_id"]) and
        identifier?(operation["destination_group_id"])

  defp valid_target?(%{"type" => type})
       when type in ["start_finance_reporting", "close_finance_period"],
       do: true

  defp valid_target?(operation), do: identifier?(operation["group_id"])

  defp valid_open_identifiers?(%{"type" => "open_group"} = operation) do
    identifier?(operation["guest_id"]) and identifier?(operation["property_id"])
  end

  defp valid_open_identifiers?(_), do: true
end
