defmodule GroupStay.Reservations.Operation do
  @moduledoc """
  Validates the partner operation envelope without coercing identifiers or money.

  Identification is separate from payload validation: an existing group's
  revision must be checked before evaluating the requested change.
  """

  @required_fields %{
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => []
  }

  def identify(operation) when is_map(operation) do
    if Map.has_key?(@required_fields, operation["type"]) and
         identifier?(operation["operation_id"]) and identifier?(operation["group_id"]) do
      :ok
    else
      {:error, :invalid_operation}
    end
  end

  def identify(_operation), do: {:error, :invalid_operation}

  def validate_payload(operation) do
    required_fields = ["occurred_on" | Map.fetch!(@required_fields, operation["type"])]

    if Enum.all?(required_fields, &Map.has_key?(operation, &1)) do
      case date(operation["occurred_on"]) do
        {:ok, occurred_on} -> {:ok, occurred_on}
        :error -> {:error, :invalid_operation}
      end
    else
      {:error, :invalid_operation}
    end
  end

  def identifier?(value), do: is_binary(value) and String.trim(value) != ""

  def date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  def date(_value), do: :error

  def id(operation) when is_map(operation), do: operation["operation_id"]
  def id(_operation), do: nil
end
