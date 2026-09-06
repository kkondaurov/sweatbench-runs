defmodule GroupStay.Operations do
  @moduledoc """
  Processes partner operations one at a time, in order, durably idempotently.

  The first operation received for an `operation_id` is processed normally
  and its exact result, applied or rejected, is stored together with its
  submitted content in the same transaction as its domain effects. A later
  operation with the same identifier and an equivalent payload replays that
  stored result without reading or changing domain state. Reusing an
  identifier with a different payload is rejected with
  `operation_id_conflict`.

  A handled rejection leaves domain state unchanged but still commits its
  record; processing continues with the next operation in the batch. An
  unexpected exception rolls back the current operation, is not remembered,
  and aborts the request.
  """

  import Ecto.Query

  alias GroupStay.Groups
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit cancel_rooms reduce_cash_payment charge_back_payment)

  @doc """
  Returns one result map per operation, in the same order as `operations`.
  """
  def process(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc """
  The stored result for an `operation_id`, or nil when no operation was
  remembered under it.
  """
  def get_stored_result(operation_id) do
    case Repo.one(from r in Record, where: r.operation_id == ^operation_id) do
      nil -> nil
      %Record{result: result} -> Jason.decode!(result)
    end
  end

  defp process_operation(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) do
    payload = canonical_payload(operation)

    try do
      run_with_memory(operation, operation_id, payload)
    rescue
      e in Ecto.ConstraintError ->
        # A concurrent transaction committed a record for this identifier after
        # our lookup. At-most-once effects are preserved because our transaction,
        # including its domain changes, rolled back.
        concurrent_replay(operation, payload, e)
    end
  end

  defp process_operation(operation), do: build_result(operation, rejected(:invalid_operation))

  defp run_with_memory(operation, operation_id, payload) do
    {:ok, result} =
      Repo.transaction(fn ->
        case find_record(operation_id) do
          %Record{} = record ->
            resolve_replay(operation, record, payload)

          nil ->
            result = build_result(operation, apply_operation(operation))
            remember!(operation_id, operation["type"], payload, result)
            result
        end
      end)

    result
  end

  defp find_record(operation_id) do
    Repo.one(from r in Record, where: r.operation_id == ^operation_id)
  end

  defp resolve_replay(operation, %Record{payload: stored_payload} = record, payload) do
    if stored_payload == payload do
      Jason.decode!(record.result)
    else
      build_result(operation, rejected(:operation_id_conflict))
    end
  end

  defp remember!(operation_id, type, payload, result) do
    Repo.insert!(%Record{
      operation_id: operation_id,
      type: if(is_binary(type), do: type),
      payload: payload,
      result: Jason.encode!(result)
    })
  end

  defp concurrent_replay(operation, payload, original_error) do
    case find_record(operation["operation_id"]) do
      %Record{payload: ^payload, result: result} -> Jason.decode!(result)
      %Record{} -> build_result(operation, rejected(:operation_id_conflict))
      nil -> raise original_error
    end
  end

  # Object key order is insignificant, array order and values are significant.
  defp canonical_payload(operation), do: IO.iodata_to_binary(canonical(operation))

  defp canonical(value) when is_map(value) do
    members =
      value
      |> Enum.map(fn {key, value} -> [?", to_string(key), ?", ?:, canonical(value)] end)
      |> Enum.sort()
      |> Enum.intersperse(?,)

    [?{, members, ?}]
  end

  defp canonical(values) when is_list(values),
    do: [?[, values |> Enum.map(&canonical/1) |> Enum.intersperse(?,), ?]]

  defp canonical(other), do: Jason.encode!(other)

  defp apply_operation(%{"type" => type, "operation_id" => operation_id} = operation)
       when is_binary(type) and is_binary(operation_id) and type in @operation_types do
    with {:ok, occurred_on} <- occurred_on(operation) do
      case type do
        "open_group" -> open_group(operation, occurred_on)
        "record_cash_payment" -> record_cash_payment(operation, occurred_on)
        "reschedule_group" -> reschedule_group(operation, occurred_on)
        "cancel_group" -> cancel_group(operation, occurred_on)
        "apply_hotel_credit" -> apply_hotel_credit(operation, occurred_on)
        "cancel_rooms" -> cancel_rooms(operation, occurred_on)
        "reduce_cash_payment" -> reduce_cash_payment(operation)
        "charge_back_payment" -> charge_back_payment(operation)
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

      Groups.record_cash_payment(
        group_id,
        amount_cents,
        expected_revision,
        operation["operation_id"]
      )
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
            "policy_version" => Groups.policy_version(group),
            "refundable_until" => iso_date_or_nil(Groups.refundable_until(group)),
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
         {:ok, expected_revision} <- optional_expected_revision(operation),
         {:ok, refund_method} <- optional_refund_method(operation) do
      Groups.cancel_group(
        group_id,
        occurred_on,
        expected_revision,
        refund_method,
        operation["operation_id"]
      )
      |> case do
        {:ok, settlement} ->
          applied(%{
            "group_id" => settlement.group.group_id,
            "refunded_cents" => settlement.refunded_cents,
            "retained_cents" => settlement.retained_cents,
            "credit_issued_cents" => settlement.credit_issued_cents,
            "revision" => settlement.group.revision
          })

        error ->
          error
      end
    end
  end

  # cancel_rooms

  defp cancel_rooms(operation, occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, room_ids} <- room_ids(operation),
         {:ok, expected_revision} <- optional_expected_revision(operation),
         {:ok, refund_method} <- optional_refund_method(operation) do
      Groups.cancel_rooms(
        group_id,
        room_ids,
        occurred_on,
        expected_revision,
        refund_method,
        operation["operation_id"]
      )
      |> case do
        {:ok, %{group: group} = settlement} ->
          applied(%{
            "group_id" => group.group_id,
            "cancelled_room_ids" => settlement.cancelled_room_ids,
            "refunded_cents" => settlement.refunded_cents,
            "retained_cents" => settlement.retained_cents,
            "credit_issued_cents" => settlement.credit_issued_cents,
            "revision" => group.revision
          })

        error ->
          error
      end
    end
  end

  defp room_ids(%{"room_ids" => room_ids}) when is_list(room_ids) do
    if Enum.all?(room_ids, &is_binary/1), do: {:ok, room_ids}, else: rejected(:invalid_operation)
  end

  defp room_ids(_operation), do: rejected(:invalid_operation)

  # reduce_cash_payment

  defp reduce_cash_payment(operation) do
    with {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id"),
         {:ok, expected_revision} <- optional_expected_revision(operation) do
      amount_cents = operation["amount_cents"]

      case payment_target(payment_operation_id, :payment_not_reducible) do
        {:ok, group_id} ->
          Groups.reduce_cash_payment(%{
            payment_operation_id: payment_operation_id,
            group_id: group_id,
            amount_cents: amount_cents,
            expected_revision: expected_revision
          })
          |> case do
            {:ok, %{group: group}} ->
              applied(%{
                "payment_operation_id" => payment_operation_id,
                "group_id" => group.group_id,
                "amount_cents" => amount_cents,
                "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
                "revision" => group.revision
              })

            error ->
              error
          end

        error ->
          error
      end
    end
  end

  # charge_back_payment

  defp charge_back_payment(operation) do
    with {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id"),
         {:ok, expected_revision} <- optional_expected_revision(operation) do
      case payment_target(payment_operation_id, :payment_not_chargeable) do
        {:ok, group_id} ->
          Groups.charge_back_payment(%{
            payment_operation_id: payment_operation_id,
            group_id: group_id,
            expected_revision: expected_revision
          })
          |> case do
            {:ok, %{group: group, charged_back_cents: charged_back_cents}} ->
              applied(%{
                "payment_operation_id" => payment_operation_id,
                "group_id" => group.group_id,
                "charged_back_cents" => charged_back_cents,
                "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
                "revision" => group.revision
              })

            error ->
              error
          end

        error ->
          error
      end
    end
  end

  # Resolves the addressed group of a durably recorded applied cash payment.
  # Any other stored target - a missing record, another operation type, or an
  # operation that was not applied - cannot be addressed through a payment.
  defp payment_target(payment_operation_id, rejection_code) do
    case find_record(payment_operation_id) do
      nil ->
        rejected(:operation_not_found)

      %Record{type: "record_cash_payment", result: result} = _record ->
        case Jason.decode!(result) do
          %{"status" => "applied", "group_id" => group_id} when is_binary(group_id) ->
            {:ok, group_id}

          _ ->
            rejected(rejection_code)
        end

      %Record{} ->
        rejected(rejection_code)
    end
  end

  @doc """
  The current disposition of one recorded cash payment for reconciliation, or
  the reason it cannot be reconciled. Reading never changes state.
  """
  def payment_statement(payment_operation_id) do
    case find_record(payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      %Record{type: "record_cash_payment", result: result} ->
        case Jason.decode!(result) do
          %{"status" => "applied"} ->
            case Groups.payment_statement(payment_operation_id) do
              nil -> {:error, :operation_not_found}
              statement -> {:ok, statement}
            end

          _ ->
            {:error, :payment_not_reconcilable}
        end

      %Record{} ->
        {:error, :payment_not_reconcilable}
    end
  end

  # apply_hotel_credit

  defp apply_hotel_credit(operation, occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, expected_revision} <- optional_expected_revision(operation) do
      amount_cents = operation["amount_cents"]

      Groups.apply_hotel_credit(group_id, amount_cents, occurred_on, expected_revision)
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

  defp optional_refund_method(operation) do
    case operation["refund_method"] do
      nil -> {:ok, "cash"}
      "cash" -> {:ok, "cash"}
      "hotel_credit" -> {:ok, "hotel_credit"}
      _ -> rejected(:invalid_operation)
    end
  end

  defp iso_date_or_nil(nil), do: nil
  defp iso_date_or_nil(date), do: Date.to_iso8601(date)

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

  defp build_result(operation, {:error, :stale_revision, details}) do
    %{
      "operation_id" => operation_id(operation),
      "status" => "rejected",
      "code" => "stale_revision",
      # Operations addressed by another identifier report the group their
      # identifier resolves to.
      "group_id" => Keyword.get(details, :group_id) || operation["group_id"],
      "expected_revision" => operation["expected_revision"],
      "actual_revision" => Keyword.fetch!(details, :actual_revision)
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
