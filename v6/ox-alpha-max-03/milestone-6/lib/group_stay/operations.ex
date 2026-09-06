defmodule GroupStay.Operations do
  @moduledoc """
  Parses partner operations into typed structs.

  Structural problems (unknown types, missing data or values of the wrong
  shape needed to identify and apply an operation) are rejected as
  `:invalid_operation`. Values that are well formed but unusable on their own,
  such as an unparseable stay date or a payment amount that cannot be applied,
  surface as the domain error codes documented in
  `docs/requests/01-operational-core.md`.
  """

  alias GroupStay.Operations.Operation

  @type operation_type ::
          :open_group
          | :record_cash_payment
          | :reschedule_group
          | :cancel_group
          | :apply_hotel_credit
          | :cancel_rooms
          | :reduce_cash_payment
          | :charge_back_payment
          | :transfer_deposit
          | :start_finance_reporting

  @types [
    :open_group,
    :record_cash_payment,
    :reschedule_group,
    :cancel_group,
    :apply_hotel_credit,
    :cancel_rooms,
    :reduce_cash_payment,
    :charge_back_payment,
    :transfer_deposit,
    :start_finance_reporting
  ]

  @spec parse(term()) ::
          {:ok, Operation.t()}
          | {:error, :invalid_operation}
          | {:error, :invalid_amount}
          | {:error, :invalid_stay}
          | {:error, :invalid_reporting_date}
  def parse(raw) when is_map(raw) do
    with {:ok, operation_id} <- require_string(fetch(raw, "operation_id")),
         {:ok, type} <- parse_type(fetch(raw, "type")),
         {:ok, occurred_on} <- common_date(fetch(raw, "occurred_on")),
         {:ok, expected_revision} <- expected_revision(fetch(raw, "expected_revision")),
         {:ok, op} <- build(type, raw, operation_id, occurred_on, expected_revision) do
      {:ok, op}
    end
  end

  def parse(_raw), do: {:error, :invalid_operation}

  defp build(type, raw, operation_id, occurred_on, expected_revision) do
    case type do
      :start_finance_reporting ->
        build_start_finance_reporting(raw, operation_id, occurred_on)

      :reduce_cash_payment ->
        build_reduce_cash_payment(raw, operation_id, occurred_on, expected_revision)

      :charge_back_payment ->
        build_charge_back_payment(raw, operation_id, occurred_on, expected_revision)

      :transfer_deposit ->
        build_transfer_deposit(raw, operation_id, occurred_on, expected_revision)

      other_type ->
        with {:ok, group_id} <- require_string(fetch(raw, "group_id")) do
          build_type(other_type, raw, operation_id, occurred_on, expected_revision, group_id)
        end
    end
  end

  defp build_type(:open_group, raw, operation_id, occurred_on, expected_revision, group_id) do
    with {:ok, guest_id} <- require_string(fetch(raw, "guest_id")),
         {:ok, property_id} <- require_string(fetch(raw, "property_id")),
         {:ok, rate_plan} <- require_string(fetch(raw, "rate_plan")),
         {:ok, arrival_on} <- stay_date(fetch(raw, "arrival_on")),
         {:ok, departure_on} <- stay_date(fetch(raw, "departure_on")),
         {:ok, rooms} <- rooms(fetch(raw, "rooms")) do
      {:ok,
       %Operation{
         operation_id: operation_id,
         type: :open_group,
         occurred_on: occurred_on,
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms,
         expected_revision: expected_revision
       }}
    end
  end

  defp build_type(
         :record_cash_payment,
         raw,
         operation_id,
         occurred_on,
         expected_revision,
         group_id
       ) do
    if has_key?(raw, "amount_cents") do
      amount = fetch(raw, "amount_cents")

      if usable_amount?(amount) do
        {:ok,
         %Operation{
           operation_id: operation_id,
           type: :record_cash_payment,
           occurred_on: occurred_on,
           group_id: group_id,
           expected_revision: expected_revision,
           amount_cents: amount
         }}
      else
        {:error, :invalid_amount}
      end
    else
      {:error, :invalid_operation}
    end
  end

  defp build_type(:reschedule_group, raw, operation_id, occurred_on, expected_revision, group_id) do
    with {:ok, new_arrival_on} <- stay_date(fetch(raw, "new_arrival_on")) do
      {:ok,
       %Operation{
         operation_id: operation_id,
         type: :reschedule_group,
         occurred_on: occurred_on,
         group_id: group_id,
         expected_revision: expected_revision,
         new_arrival_on: new_arrival_on
       }}
    end
  end

  defp build_type(:cancel_group, raw, operation_id, occurred_on, expected_revision, group_id) do
    with {:ok, refund_method} <- refund_method(fetch(raw, "refund_method")) do
      {:ok,
       %Operation{
         operation_id: operation_id,
         type: :cancel_group,
         occurred_on: occurred_on,
         group_id: group_id,
         expected_revision: expected_revision,
         refund_method: refund_method
       }}
    end
  end

  defp build_type(
         :apply_hotel_credit,
         raw,
         operation_id,
         occurred_on,
         expected_revision,
         group_id
       ) do
    if has_key?(raw, "amount_cents") do
      amount = fetch(raw, "amount_cents")

      if usable_amount?(amount) do
        {:ok,
         %Operation{
           operation_id: operation_id,
           type: :apply_hotel_credit,
           occurred_on: occurred_on,
           group_id: group_id,
           expected_revision: expected_revision,
           amount_cents: amount
         }}
      else
        {:error, :invalid_amount}
      end
    else
      {:error, :invalid_operation}
    end
  end

  defp build_type(:cancel_rooms, raw, operation_id, occurred_on, expected_revision, group_id) do
    with {:ok, room_ids} <- room_ids(fetch(raw, "room_ids")),
         {:ok, refund_method} <- refund_method(fetch(raw, "refund_method")) do
      {:ok,
       %Operation{
         operation_id: operation_id,
         type: :cancel_rooms,
         occurred_on: occurred_on,
         group_id: group_id,
         expected_revision: expected_revision,
         refund_method: refund_method,
         room_ids: room_ids
       }}
    end
  end

  # Reporting inception addresses no group, so it has no revision guard; only
  # its `starts_on` date is required. A missing or unusable date is rejected
  # as `invalid_reporting_date`.
  defp build_start_finance_reporting(raw, operation_id, occurred_on) do
    with {:ok, starts_on} <- reporting_date(fetch(raw, "starts_on")) do
      {:ok,
       %Operation{
         operation_id: operation_id,
         type: :start_finance_reporting,
         occurred_on: occurred_on,
         starts_on: starts_on
       }}
    end
  end

  defp build_reduce_cash_payment(raw, operation_id, occurred_on, expected_revision) do
    with {:ok, payment_operation_id} <- require_string(fetch(raw, "payment_operation_id")) do
      if has_key?(raw, "amount_cents") do
        amount = fetch(raw, "amount_cents")

        if usable_amount?(amount) do
          {:ok,
           %Operation{
             operation_id: operation_id,
             type: :reduce_cash_payment,
             occurred_on: occurred_on,
             payment_operation_id: payment_operation_id,
             expected_revision: expected_revision,
             amount_cents: amount
           }}
        else
          {:error, :invalid_amount}
        end
      else
        {:error, :invalid_operation}
      end
    end
  end

  defp build_charge_back_payment(raw, operation_id, occurred_on, expected_revision) do
    with {:ok, payment_operation_id} <- require_string(fetch(raw, "payment_operation_id")) do
      {:ok,
       %Operation{
         operation_id: operation_id,
         type: :charge_back_payment,
         occurred_on: occurred_on,
         payment_operation_id: payment_operation_id,
         expected_revision: expected_revision
       }}
    end
  end

  # The amount is validated by the domain rules after both groups exist and
  # their revisions are checked; only its presence is structural here.
  defp build_transfer_deposit(raw, operation_id, occurred_on, expected_revision) do
    with {:ok, source_group_id} <- require_string(fetch(raw, "source_group_id")),
         {:ok, destination_group_id} <- require_string(fetch(raw, "destination_group_id")),
         {:ok, destination_expected_revision} <-
           expected_revision(fetch(raw, "destination_expected_revision")) do
      if has_key?(raw, "amount_cents") do
        {:ok,
         %Operation{
           operation_id: operation_id,
           type: :transfer_deposit,
           occurred_on: occurred_on,
           source_group_id: source_group_id,
           destination_group_id: destination_group_id,
           destination_expected_revision: destination_expected_revision,
           expected_revision: expected_revision,
           amount_cents: fetch(raw, "amount_cents")
         }}
      else
        {:error, :invalid_operation}
      end
    end
  end

  # Omitting refund_method preserves the historical cash settlement.
  defp refund_method(nil), do: {:ok, :cash}
  defp refund_method("cash"), do: {:ok, :cash}
  defp refund_method("hotel_credit"), do: {:ok, :hotel_credit}
  defp refund_method(_refund_method), do: {:error, :invalid_operation}

  defp parse_type(type) when type in @types, do: {:ok, type}

  defp parse_type(type) when is_binary(type) do
    type_atom = existing_atom(type)
    if type_atom in @types, do: {:ok, type_atom}, else: {:error, :invalid_operation}
  end

  defp parse_type(_type), do: {:error, :invalid_operation}

  defp rooms(rooms) when is_list(rooms) do
    Enum.reduce_while(rooms, {:ok, []}, fn room, {:ok, acc} ->
      parsed_room = parse_room(room)

      case parsed_room do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp rooms(_rooms), do: {:error, :invalid_operation}

  defp room_ids(room_ids) when is_list(room_ids) do
    Enum.reduce_while(room_ids, {:ok, []}, fn room_id, {:ok, acc} ->
      case require_string(room_id) do
        {:ok, room_id} -> {:cont, {:ok, [room_id | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp room_ids(_room_ids), do: {:error, :invalid_operation}

  defp parse_room(room) when is_map(room) do
    room_id = fetch(room, "room_id")
    nightly_rate_cents = fetch(room, "nightly_rate_cents")

    if is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) do
      {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}}
    else
      {:error, :invalid_operation}
    end
  end

  defp parse_room(_room), do: {:error, :invalid_operation}

  # Stay dates carry domain meaning: a date-shaped value that cannot be read
  # is an unusable date (`invalid_stay`). Absent values or values that are not
  # even date-shaped leave nothing to validate and are `invalid_operation`.
  defp stay_date(nil), do: {:error, :invalid_operation}

  defp stay_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_stay}
    end
  end

  defp stay_date(_value), do: {:error, :invalid_operation}

  defp common_date(nil), do: {:error, :invalid_operation}

  defp common_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_operation}
    end
  end

  defp common_date(_value), do: {:error, :invalid_operation}

  # Both a missing and an unusable `starts_on` are rejected as
  # `invalid_reporting_date`.
  defp reporting_date(nil), do: {:error, :invalid_reporting_date}

  defp reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_reporting_date}
    end
  end

  defp reporting_date(_value), do: {:error, :invalid_reporting_date}

  defp expected_revision(nil), do: {:ok, nil}

  defp expected_revision(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp expected_revision(_value), do: {:error, :invalid_operation}

  defp usable_amount?(value), do: is_integer(value) and value > 0

  defp require_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp require_string(_value), do: {:error, :invalid_operation}

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, existing_atom(key))

  defp fetch(map, key) when is_binary(key) do
    if Map.has_key?(map, key) do
      Map.fetch!(map, key)
    else
      atom = existing_atom(key)
      Map.get(map, atom)
    end
  end

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
