defmodule GroupStay.Operations do
  @moduledoc """
  Processes partner operations one at a time, in order.

  Each operation runs in its own database transaction. A rejected operation
  leaves the database exactly as it was before the operation began, and
  processing always continues with the next operation.
  """

  alias GroupStay.Groups

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group)

  @doc """
  Returns one result map per operation, in the same order as `operations`.
  """
  def process(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  defp process_operation(operation) do
    outcome =
      try do
        apply_operation(operation)
      rescue
        _ -> {:error, :invalid_operation}
      end

    build_result(operation, outcome)
  end

  defp apply_operation(%{"type" => type, "operation_id" => operation_id} = operation)
       when is_binary(type) and is_binary(operation_id) and type in @operation_types do
    with {:ok, occurred_on} <- occurred_on(operation) do
      case type do
        "open_group" -> open_group(operation, occurred_on)
        "record_cash_payment" -> record_cash_payment(operation, occurred_on)
        "reschedule_group" -> reschedule_group(operation, occurred_on)
        "cancel_group" -> cancel_group(operation, occurred_on)
      end
    end
  end

  defp apply_operation(_operation), do: rejected(:invalid_operation)

  # open_group

  defp open_group(operation, booked_on) do
    with {:ok, attrs} <- open_group_fields(operation, booked_on) do
      case Groups.open_group(attrs) do
        {:ok, group} ->
          applied(%{
            "group_id" => group.group_id,
            "deposit_due_cents" => group.deposit_due_cents,
            "revision" => group.revision
          })

        error ->
          error
      end
    end
  end

  defp open_group_fields(operation, booked_on) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, arrival_on} <- stay_date(operation, "arrival_on"),
         {:ok, departure_on} <- stay_date(operation, "departure_on"),
         {:ok, rate_plan} <- required_string(operation, "rate_plan"),
         {:ok, rooms} <- rooms(operation["rooms"]) do
      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       }}
    end
  end

  defp rooms(rooms) when is_list(rooms) do
    parsed =
      Enum.map(rooms, fn room ->
        case room do
          %{"room_id" => room_id, "nightly_rate_cents" => rate}
          when is_binary(room_id) and is_integer(rate) ->
            %{room_id: room_id, nightly_rate_cents: rate}

          _ ->
            :invalid_room
        end
      end)

    if :invalid_room in parsed, do: rejected(:invalid_operation), else: {:ok, parsed}
  end

  defp rooms(_rooms), do: rejected(:invalid_operation)

  # record_cash_payment

  defp record_cash_payment(operation, _occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, expected_revision} <- optional_expected_revision(operation) do
      amount_cents = operation["amount_cents"]

      Groups.record_cash_payment(group_id, amount_cents, expected_revision)
      |> case do
        {:ok, group} ->
          applied(%{
            "group_id" => group.group_id,
            "amount_cents" => amount_cents,
            "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
            "revision" => group.revision
          })

        error ->
          error
      end
    end
  end

  # reschedule_group

  defp reschedule_group(operation, occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, expected_revision} <- optional_expected_revision(operation),
         {:ok, new_arrival_on} <- new_arrival_on(operation) do
      Groups.reschedule_group(group_id, new_arrival_on, occurred_on, expected_revision)
      |> case do
        {:ok, group} ->
          applied(%{
            "group_id" => group.group_id,
            "new_arrival_on" => Date.to_iso8601(group.arrival_on),
            "new_departure_on" => Date.to_iso8601(group.departure_on),
            "revision" => group.revision
          })

        error ->
          error
      end
    end
  end

  # cancel_group

  defp cancel_group(operation, occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, expected_revision} <- optional_expected_revision(operation) do
      Groups.cancel_group(group_id, occurred_on, expected_revision)
      |> case do
        {:ok, group} ->
          applied(%{
            "group_id" => group.group_id,
            "refunded_cents" => group.refunded_cents,
            "retained_cents" => group.retained_cents,
            "revision" => group.revision
          })

        error ->
          error
      end
    end
  end

  # Shared field handling

  defp occurred_on(operation) do
    case operation["occurred_on"] do
      nil -> rejected(:invalid_operation)
      value -> parse_date(value, :invalid_operation)
    end
  end

  defp stay_date(operation, key) do
    case operation[key] do
      nil -> rejected(:invalid_operation)
      value -> parse_date(value, :invalid_stay)
    end
  end

  defp new_arrival_on(operation) do
    case operation["new_arrival_on"] do
      nil -> rejected(:invalid_operation)
      value -> parse_date(value, :invalid_stay)
    end
  end

  defp required_string(operation, key) do
    case operation[key] do
      value when is_binary(value) -> {:ok, value}
      _ -> rejected(:invalid_operation)
    end
  end

  defp optional_expected_revision(operation) do
    {:ok, operation["expected_revision"]}
  end

  defp parse_date(value, failure_code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> rejected(failure_code)
    end
  end

  defp parse_date(_value, failure_code), do: rejected(failure_code)

  # Results

  defp operation_id(operation) when is_map(operation), do: operation["operation_id"]
  defp operation_id(_operation), do: nil

  defp applied(extra), do: {:applied, extra}

  defp rejected(code), do: {:error, code}

  defp build_result(operation, {:applied, extra}) do
    Map.merge(%{"operation_id" => operation_id(operation), "status" => "applied"}, extra)
  end

  defp build_result(operation, {:error, :stale_revision, [actual_revision: actual_revision]}) do
    %{
      "operation_id" => operation_id(operation),
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => operation["group_id"],
      "expected_revision" => operation["expected_revision"],
      "actual_revision" => actual_revision
    }
  end

  defp build_result(operation, {:error, code}) when is_atom(code) do
    %{
      "operation_id" => operation_id(operation),
      "status" => "rejected",
      "code" => to_string(code)
    }
  end
end
