defmodule GroupStay.Reservations.Operation do
  @moduledoc "Validates partner operation envelopes without coercing identifiers or money."

  @required %{
    "start_finance_reporting" => [],
    "transfer_deposit" => ~w(source_group_id destination_group_id amount_cents),
    "open_group" => ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(group_id amount_cents),
    "reschedule_group" => ~w(group_id new_arrival_on),
    "apply_hotel_credit" => ~w(group_id amount_cents),
    "cancel_group" => ~w(group_id),
    "cancel_rooms" => ~w(group_id room_ids),
    "reduce_cash_payment" => ~w(payment_operation_id amount_cents),
    "charge_back_payment" => ~w(payment_operation_id)
  }

  def validate(operation) when is_map(operation) do
    with fields when is_list(fields) <- Map.get(@required, operation["type"]),
         true <- Enum.all?(fields, &Map.has_key?(operation, &1)),
         true <- identifier?(operation["operation_id"]),
         true <- valid_targets?(operation, fields),
         {:ok, occurred_on} <- date(operation["occurred_on"]) do
      {:ok, occurred_on}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  def validate(_), do: {:error, "invalid_operation"}

  defp valid_targets?(operation, fields) do
    targets =
      Enum.filter(
        fields,
        &(&1 in ~w(group_id payment_operation_id source_group_id destination_group_id))
      )

    Enum.all?(targets, &identifier?(operation[&1]))
  end

  def identifier?(value), do: is_binary(value) and byte_size(value) > 0

  def date(value) when is_binary(value), do: Date.from_iso8601(value)
  def date(_), do: {:error, :invalid_date}
end
