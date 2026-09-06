defmodule GroupStay.Operations do
  @moduledoc """
  Parses partner operations from a decoded JSON batch, applies them in array
  order, and produces one API result per operation.

  A rejected operation never touches domain state and never stops later
  operations. Unknown operation types and operations missing data needed to
  identify or apply them are rejected with `invalid_operation`.

  Operations carrying an `operation_id` are durably idempotent: the first
  submission is processed normally and remembered — applied or rejected — in
  the same transaction as its domain changes. A later identical submission
  returns the stored result verbatim without reading or changing domain
  state, while a different payload under a taken identifier is rejected with
  `operation_id_conflict`. An unexpected exception rolls back the whole
  operation, remembers nothing, and aborts the request.
  """

  alias GroupStay.Finance
  alias GroupStay.Groups
  alias GroupStay.Operations.Payload
  alias GroupStay.Operations.Record
  alias GroupStay.Payments
  alias GroupStay.Repo
  alias GroupStay.Transfers

  @invalid_operation "invalid_operation"
  @invalid_stay "invalid_stay"
  @invalid_rooms "invalid_rooms"
  @operation_id_conflict "operation_id_conflict"
  @invalid_reporting_date "invalid_reporting_date"
  @invalid_period "invalid_period"

  @doc """
  Runs a batch's `operations` list, returning `{:ok, results}` with one result
  per operation in order, or `:error` when the body has no operations array.
  """
  def run_batch(operations) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def run_batch(_operations), do: :error

  defp process_operation(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) and operation_id != "" do
    case Record.fetch(operation_id) do
      nil -> execute_and_remember(operation_id, operation)
      record -> replay_or_conflict(record, operation)
    end
  end

  defp process_operation(operation), do: apply_operation(operation)

  defp replay_or_conflict(record, operation) do
    if record.submitted_json == Payload.canonical_json(operation) do
      Record.stored_result(record)
    else
      reject(operation, @operation_id_conflict)
    end
  end

  # Applies the operation and commits its durable record atomically with any
  # domain changes. A handled rejection still commits its record; an
  # unexpected exception rolls everything back and propagates.
  defp execute_and_remember(operation_id, operation) do
    Repo.transaction(fn ->
      result = apply_operation(operation)

      case Record.insert(operation_id, operation, result) do
        :ok ->
          result

        # A concurrent submission won the identifier: discard everything this
        # transaction did and answer with the winner's stored outcome.
        {:conflict, %Record{} = record} ->
          if record.submitted_json == Payload.canonical_json(operation) do
            Repo.rollback({:lost_race, record})
          else
            Repo.rollback({:operation_id_conflict, operation})
          end

        # The insert failed without a concurrent winner: nothing about this
        # operation is remembered or applied.
        {:conflict, nil} ->
          raise "failed to persist the durable record for operation #{inspect(operation_id)}"
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, {:lost_race, record}} -> Record.stored_result(record)
      {:error, {:operation_id_conflict, operation}} -> conflict_rejection(operation)
    end
  end

  defp conflict_rejection(operation), do: reject(operation, @operation_id_conflict)

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: reschedule_group(operation)

  defp apply_operation(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp apply_operation(%{"type" => "cancel_rooms"} = operation), do: cancel_rooms(operation)

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp apply_operation(%{"type" => "reduce_cash_payment"} = operation),
    do: reduce_cash_payment(operation)

  defp apply_operation(%{"type" => "charge_back_payment"} = operation),
    do: charge_back_payment(operation)

  defp apply_operation(%{"type" => "transfer_deposit"} = operation),
    do: transfer_deposit(operation)

  defp apply_operation(%{"type" => "start_finance_reporting"} = operation),
    do: start_finance_reporting(operation)

  defp apply_operation(%{"type" => "close_finance_period"} = operation),
    do: close_finance_period(operation)

  defp apply_operation(operation) when is_map(operation),
    do: reject(operation, @invalid_operation)

  defp apply_operation(_operation), do: reject(%{}, @invalid_operation)

  defp open_group(operation) do
    with {:ok, occurred_on} <- occurred_on(operation),
         {:ok, group_id} <- group_id(operation),
         {:ok, arrival_on} <- stay_date(operation, "arrival_on"),
         {:ok, departure_on} <- stay_date(operation, "departure_on"),
         {:ok, rooms} <- rooms(operation),
         {:ok, guest_id} <- optional_identifier(operation["guest_id"]),
         {:ok, property_id} <- optional_identifier(operation["property_id"]) do
      attrs = [
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        rooms: rooms
      ]

      case Groups.open_group(attrs) do
        {:ok, group} ->
          applied(operation, %{
            "group_id" => group.group_id,
            "deposit_due_cents" => group.deposit_due_cents,
            "revision" => group.revision
          })

        {:error, code} ->
          reject(operation, Atom.to_string(code), %{"group_id" => group_id})
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, occurred_on} <- occurred_on(operation),
         {:ok, group_id} <- group_id(operation) do
      case Groups.record_cash_payment(group_id, operation["amount_cents"],
             expected_revision: expected_revision(operation),
             operation_id: operation_id(operation),
             occurred_on: occurred_on
           ) do
        {:ok, outcome} ->
          applied(operation, %{
            "group_id" => group_id,
            "amount_cents" => outcome.amount_cents,
            "outstanding_deposit_cents" => outcome.outstanding_deposit_cents,
            "revision" => outcome.revision
          })

        {:error, reason} ->
          reject_outcome(operation, group_id, reason)
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp reschedule_group(operation) do
    with {:ok, occurred_on} <- occurred_on(operation),
         {:ok, group_id} <- group_id(operation),
         {:ok, new_arrival_on} <- stay_date(operation, "new_arrival_on") do
      case Groups.reschedule_group(
             group_id,
             new_arrival_on,
             occurred_on,
             expected_revision(operation)
           ) do
        {:ok, outcome} ->
          applied(operation, %{
            "group_id" => group_id,
            "new_arrival_on" => Date.to_iso8601(outcome.new_arrival_on),
            "new_departure_on" => Date.to_iso8601(outcome.new_departure_on),
            "policy_version" => outcome.policy_version,
            "refundable_until" => iso_date(outcome.refundable_until),
            "revision" => outcome.revision
          })

        {:error, reason} ->
          reject_outcome(operation, group_id, reason)
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp cancel_group(operation) do
    with {:ok, occurred_on} <- occurred_on(operation),
         {:ok, group_id} <- group_id(operation),
         {:ok, refund_method} <- refund_method(operation) do
      case Groups.cancel_group(group_id, occurred_on,
             expected_revision: expected_revision(operation),
             refund_method: refund_method,
             source_operation_id: operation_id(operation)
           ) do
        {:ok, outcome} ->
          applied(operation, %{
            "group_id" => group_id,
            "refunded_cents" => outcome.refunded_cents,
            "retained_cents" => outcome.retained_cents,
            "credit_issued_cents" => outcome.credit_issued_cents,
            "revision" => outcome.revision
          })

        {:error, reason} ->
          reject_outcome(operation, group_id, reason)
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, occurred_on} <- occurred_on(operation),
         {:ok, group_id} <- group_id(operation) do
      case Groups.apply_hotel_credit(group_id, operation["amount_cents"], occurred_on,
             expected_revision: expected_revision(operation),
             operation_id: operation_id(operation)
           ) do
        {:ok, outcome} ->
          applied(operation, %{
            "group_id" => group_id,
            "amount_cents" => outcome.amount_cents,
            "outstanding_deposit_cents" => outcome.outstanding_deposit_cents,
            "revision" => outcome.revision
          })

        {:error, reason} ->
          reject_outcome(operation, group_id, reason)
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, occurred_on} <- occurred_on(operation),
         {:ok, group_id} <- group_id(operation),
         {:ok, refund_method} <- refund_method(operation),
         {:ok, room_ids} <- room_ids(operation) do
      case Groups.cancel_rooms(group_id, room_ids, occurred_on,
             expected_revision: expected_revision(operation),
             refund_method: refund_method,
             source_operation_id: operation_id(operation)
           ) do
        {:ok, outcome} ->
          applied(operation, %{
            "group_id" => group_id,
            "cancelled_room_ids" => outcome.cancelled_room_ids,
            "refunded_cents" => outcome.refunded_cents,
            "retained_cents" => outcome.retained_cents,
            "credit_issued_cents" => outcome.credit_issued_cents,
            "revision" => outcome.revision
          })

        {:error, reason} ->
          reject_outcome(operation, group_id, reason)
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, _occurred_on} <- occurred_on(operation),
         {:ok, payment_operation_id} <- payment_operation_id(operation) do
      case Payments.reduce_cash_payment(
             payment_operation_id,
             operation["amount_cents"],
             expected_revision(operation),
             parsed_date(operation["occurred_on"])
           ) do
        {:ok, outcome} ->
          applied(operation, %{
            "payment_operation_id" => payment_operation_id,
            "group_id" => outcome.group_id,
            "amount_cents" => outcome.amount_cents,
            "outstanding_deposit_cents" => outcome.outstanding_deposit_cents,
            "revision" => outcome.revision
          })

        {:error, reason, extra} ->
          reject(operation, Atom.to_string(reason), string_keys(extra))
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, _occurred_on} <- occurred_on(operation),
         {:ok, payment_operation_id} <- payment_operation_id(operation) do
      case Payments.charge_back_payment(
             payment_operation_id,
             expected_revision(operation),
             parsed_date(operation["occurred_on"])
           ) do
        {:ok, outcome} ->
          applied(operation, %{
            "payment_operation_id" => payment_operation_id,
            "group_id" => outcome.group_id,
            "charged_back_cents" => outcome.charged_back_cents,
            "outstanding_deposit_cents" => outcome.outstanding_deposit_cents,
            "revision" => outcome.revision
          })

        {:error, reason, extra} ->
          reject(operation, Atom.to_string(reason), string_keys(extra))
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, _occurred_on} <- occurred_on(operation),
         {:ok, source_group_id} <- source_group_id(operation),
         {:ok, destination_group_id} <- destination_group_id(operation) do
      case Transfers.transfer_deposit(
             source_group_id,
             destination_group_id,
             operation["amount_cents"],
             expected_revision: expected_revision(operation),
             destination_expected_revision: operation["destination_expected_revision"],
             occurred_on: parsed_date(operation["occurred_on"])
           ) do
        {:ok, outcome} ->
          applied(operation, %{
            "source_group_id" => outcome.source_group_id,
            "destination_group_id" => outcome.destination_group_id,
            "amount_cents" => outcome.amount_cents,
            "source_outstanding_deposit_cents" => outcome.source_outstanding_deposit_cents,
            "destination_outstanding_deposit_cents" =>
              outcome.destination_outstanding_deposit_cents,
            "source_revision" => outcome.source_revision,
            "destination_revision" => outcome.destination_revision
          })

        {:error, reason, extra} ->
          reject(operation, Atom.to_string(reason), string_keys(extra))
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  # Starts finance reporting: no group is addressed and there is no revision
  # guard. The first applied start enables reporting; a later start with a
  # different identifier is rejected, while retries of the original follow
  # the durable replay and conflict rules before this code ever runs.
  defp start_finance_reporting(operation) do
    case parse_date(operation["starts_on"]) do
      {:ok, starts_on} ->
        case Finance.start_reporting(starts_on) do
          :ok ->
            applied(operation, %{"starts_on" => Date.to_iso8601(starts_on)})

          {:error, :reporting_already_started} ->
            reject(operation, "reporting_already_started")
        end

      :error ->
        reject(operation, @invalid_reporting_date)
    end
  end

  # Closes the finance period through `period_end_on`: no group is addressed
  # and there is no revision guard. It applies only once reporting has
  # started, on or after `starts_on`, and strictly later than the latest
  # successful close; everything else — including an unusable date, which
  # names no period at all — is rejected with `invalid_period`. Retries of
  # the same identifier follow the durable replay and conflict rules before
  # this code ever runs.
  defp close_finance_period(operation) do
    case parse_date(operation["period_end_on"]) do
      {:ok, period_end_on} ->
        case Finance.close_through(period_end_on) do
          :ok ->
            applied(operation, %{"period_end_on" => Date.to_iso8601(period_end_on)})

          {:error, :invalid_period} ->
            reject(operation, @invalid_period)
        end

      :error ->
        reject(operation, @invalid_period)
    end
  end

  defp reject_outcome(operation, group_id, {:stale_revision, expected, actual}) do
    reject(operation, "stale_revision", %{
      "group_id" => group_id,
      "expected_revision" => expected,
      "actual_revision" => actual
    })
  end

  defp reject_outcome(operation, group_id, reason) do
    reject(operation, Atom.to_string(reason), %{"group_id" => group_id})
  end

  defp occurred_on(operation) do
    case parse_date(operation["occurred_on"]) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, @invalid_operation}
    end
  end

  defp group_id(operation) do
    case identifier(operation["group_id"]) do
      {:ok, group_id} -> {:ok, group_id}
      :error -> {:error, @invalid_operation}
    end
  end

  defp room_ids(operation) do
    case operation["room_ids"] do
      room_ids when is_list(room_ids) -> {:ok, room_ids}
      _other -> {:error, @invalid_operation}
    end
  end

  defp payment_operation_id(operation) do
    case identifier(operation["payment_operation_id"]) do
      {:ok, payment_operation_id} -> {:ok, payment_operation_id}
      :error -> {:error, @invalid_operation}
    end
  end

  defp source_group_id(operation) do
    case identifier(operation["source_group_id"]) do
      {:ok, source_group_id} -> {:ok, source_group_id}
      :error -> {:error, @invalid_operation}
    end
  end

  defp destination_group_id(operation) do
    case identifier(operation["destination_group_id"]) do
      {:ok, destination_group_id} -> {:ok, destination_group_id}
      :error -> {:error, @invalid_operation}
    end
  end

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp stay_date(operation, key) do
    case parse_date(operation[key]) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, @invalid_stay}
    end
  end

  defp rooms(operation) do
    case normalize_rooms(operation["rooms"]) do
      {:ok, rooms} -> {:ok, rooms}
      :error -> {:error, @invalid_rooms}
    end
  end

  defp normalize_rooms(rooms) when is_list(rooms) and rooms != [] do
    normalized =
      Enum.reduce_while(rooms, {:ok, []}, fn room, {:ok, acc} ->
        case normalize_room(room) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          :error -> {:halt, :error}
        end
      end)

    with {:ok, rooms} <- normalized,
         true <- Enum.uniq_by(rooms, & &1.room_id) == rooms do
      {:ok, Enum.reverse(rooms)}
    else
      _other -> :error
    end
  end

  defp normalize_rooms(_rooms), do: :error

  defp normalize_room(room) when is_map(room) do
    with {:ok, room_id} <- identifier(room["room_id"]),
         true <- usable_rate?(room["nightly_rate_cents"]) do
      {:ok, %{room_id: room_id, nightly_rate_cents: room["nightly_rate_cents"]}}
    else
      _other -> :error
    end
  end

  defp normalize_room(_room), do: :error

  defp usable_rate?(rate) when is_integer(rate) and rate > 0, do: true
  defp usable_rate?(_rate), do: false

  defp identifier(value) when is_binary(value) and value != "", do: {:ok, value}
  defp identifier(_value), do: :error

  defp optional_identifier(nil), do: {:ok, nil}

  defp optional_identifier(value) do
    case identifier(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, @invalid_operation}
    end
  end

  defp expected_revision(operation) do
    operation["expected_revision"]
  end

  defp refund_method(operation) do
    case operation["refund_method"] do
      nil -> {:ok, :cash}
      "cash" -> {:ok, :cash}
      "hotel_credit" -> {:ok, :hotel_credit}
      _other -> {:error, @invalid_operation}
    end
  end

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp parsed_date(value) do
    case parse_date(value) do
      {:ok, date} -> date
      :error -> nil
    end
  end

  defp applied(operation, fields) do
    Map.merge(
      %{"operation_id" => operation_id(operation), "status" => "applied"},
      fields
    )
  end

  defp reject(operation, code, extra \\ %{}) do
    Map.merge(
      %{"operation_id" => operation_id(operation), "status" => "rejected", "code" => code},
      extra
    )
  end

  defp operation_id(operation) do
    case operation do
      %{"operation_id" => value} -> value
      _other -> nil
    end
  end
end
