defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in batch order and reports the outcome of each one.

  Every operation runs in its own transaction. A handled outcome — applied or
  rejected — commits a durable idempotency record in the same transaction as
  any domain changes. A later operation with the same `operation_id` and an
  equivalent payload returns the stored result without reading or changing
  domain state; a different payload is rejected with `operation_id_conflict`
  and leaves the original record in place. An unexpected exception rolls back
  the operation, is not remembered, and aborts the request so the gateway can
  retry the batch. Processing continues with the next operation after every
  handled rejection.

  Cash and credit fund active rooms in the rooms' original order, filling one
  room's deposit before moving to the next; each funding operation allocates
  in operation-processing order. Cancellations settle the selected rooms'
  allocations, and payment reductions and chargebacks reclassify the
  dispositions of one recorded payment. Deposit transfers move held funding
  between two active groups of the same guest without settling or revaluing
  it. An applied operation increments the revision of every group whose state
  it changes, and always the group it is addressed to.

  Once finance reporting has started, an applied operation also posts its
  finance effects to the daily report at the later of its `occurred_on` and
  the reporting start date, in the same transaction as the domain changes.
  After a `close_finance_period` operation has closed a period, an operation
  whose posting date falls inside the closed period posts on the day after
  the latest cutoff instead, keeping every closed report unchanged; such
  movements are reported as late adjustments. Rejected operations post
  nothing.
  """

  import Ecto.Query

  alias GroupStay.{Finance, Repo}
  alias GroupStay.Finance.Credit
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.Report
  alias GroupStay.Finance.RoomAllocation
  alias GroupStay.Finance.RoomAllocations
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Policy
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.CanonicalJson
  alias GroupStay.Operations.OperationRecord

  @known_types ~w(open_group record_cash_payment reschedule_group cancel_group
                   apply_hotel_credit cancel_rooms reduce_cash_payment
                   charge_back_payment transfer_deposit start_finance_reporting
                   close_finance_period)
  @rate_plans ~w(flexible advance_purchase)
  @refund_methods ~w(cash hotel_credit)
  @flexible_deposit_percent 20
  @credit_bonus_percent 10

  @doc """
  Applies each operation in order and returns one result per operation.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Applies a single raw operation and returns its result map.

  The first operation received for an `operation_id` is processed and its
  outcome remembered. A later operation with the same identifier and an
  equivalent payload replays the stored result; a different payload is
  rejected with `operation_id_conflict`.
  """
  def apply_operation(raw) do
    case parse(raw) do
      {:ok, op} ->
        run(op.operation_id, raw, fn -> apply_op(op) end)

      :invalid ->
        case operation_id_of(raw) do
          nil ->
            rejection(nil, "invalid_operation", group_id_of(raw))

          operation_id ->
            run(operation_id, raw, fn ->
              rejection(operation_id, "invalid_operation", group_id_of(raw))
            end)
        end
    end
  end

  @doc """
  Returns the stored result for the given operation identifier, or `:error`
  when no operation with that identifier has been handled.
  """
  def fetch_result(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> :error
      %OperationRecord{} = record -> {:ok, Jason.decode!(record.result)}
    end
  end

  @doc """
  Returns the current disposition of the cash recorded by one durably
  stored, applied cash payment.

  Returns `{:error, :operation_not_found}` when no durable operation record
  exists for the identifier, and `{:error, :payment_not_reconcilable}` when
  the record exists but is not an applied cash payment.
  """
  def payment_statement(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      record ->
        case stored_applied_payment(record, "payment_not_reconcilable") do
          {:ok, payment} -> {:ok, statement(payment)}
          {:reject, _, _} -> {:error, :payment_not_reconcilable}
        end
    end
  end

  defp statement(payment) do
    sums = RoomAllocations.disposition_sums(payment.operation_id)

    statement = %{
      payment_operation_id: payment.operation_id,
      original_group_id: payment.group_id,
      recorded_cents: payment.amount_cents,
      held_cents: Map.get(sums, "held", 0),
      refunded_cents: Map.get(sums, "refunded", 0),
      retained_cents: Map.get(sums, "retained", 0),
      converted_to_credit_cents: Map.get(sums, "converted", 0),
      reduced_cents: Map.get(sums, "reduced", 0),
      charged_back_cents: Map.get(sums, "charged_back", 0)
    }

    if RoomAllocations.cash_transferred?(payment.operation_id) do
      Map.put(statement, :held_by_group, RoomAllocations.held_by_group(payment.operation_id))
    else
      statement
    end
  end

  # Idempotency

  defp run(operation_id, raw, compute) do
    payload = CanonicalJson.encode!(raw)

    case Repo.transaction(fn -> resolve(operation_id, raw, payload, compute) end) do
      {:ok, result} -> result
      {:error, {:stored, result}} -> result
      {:error, error} -> raise "operation could not be applied: #{inspect(error)}"
    end
  end

  defp resolve(operation_id, raw, payload, compute) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> commit_new(operation_id, raw, payload, compute)
      %OperationRecord{} = record -> stored_result(operation_id, raw, payload, record)
    end
  end

  defp commit_new(operation_id, raw, payload, compute) do
    result = compute.()

    try do
      insert_record(operation_id, raw, payload, result)
      result
    rescue
      insert_error ->
        # The insert only fails once a concurrent submission has committed this
        # operation_id first; roll back the duplicated effects and answer with
        # the committed outcome. Any other failure is re-raised so the
        # operation rolls back and is not remembered.
        case Repo.get_by(OperationRecord, operation_id: operation_id) do
          nil -> reraise insert_error, __STACKTRACE__
          record -> Repo.rollback({:stored, stored_result(operation_id, raw, payload, record)})
        end
    end
  end

  defp stored_result(operation_id, raw, payload, %OperationRecord{} = record) do
    if record.payload == payload do
      Jason.decode!(record.result)
    else
      rejection(operation_id, "operation_id_conflict", group_id_of(raw))
    end
  end

  defp insert_record(operation_id, raw, payload, result) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(OperationRecord, [
      %{
        operation_id: operation_id,
        type: type_of(raw),
        payload: payload,
        result: Jason.encode!(result),
        inserted_at: now,
        updated_at: now
      }
    ])

    :ok
  end

  defp type_of(raw) when is_map(raw) do
    case Map.get(raw, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp type_of(_raw), do: nil

  # Parsing

  defp parse(raw) when not is_map(raw), do: :invalid

  defp parse(raw) do
    with {:ok, operation_id} <- fetch_binary(raw, "operation_id"),
         {:ok, type} <- fetch_binary(raw, "type"),
         true <- type in @known_types,
         {:ok, occurred_on} <- fetch_date(raw, "occurred_on"),
         {:ok, fields} <- parse_fields(type, raw) do
      {:ok,
       Map.merge(fields, %{
         operation_id: operation_id,
         type: type,
         occurred_on: occurred_on,
         expected_revision: Map.get(raw, "expected_revision")
       })}
    else
      _ -> :invalid
    end
  end

  defp parse_fields("open_group", raw) do
    with {:ok, group_id} <- fetch_binary(raw, "group_id"),
         {:ok, guest_id} <- fetch_binary(raw, "guest_id"),
         {:ok, property_id} <- fetch_binary(raw, "property_id"),
         {:ok, arrival_on} <- fetch_binary(raw, "arrival_on"),
         {:ok, departure_on} <- fetch_binary(raw, "departure_on"),
         {:ok, rate_plan} <- fetch_binary(raw, "rate_plan"),
         {:ok, rooms} <- fetch_list(raw, "rooms") do
      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       }}
    end
  end

  defp parse_fields("record_cash_payment", raw) do
    with {:ok, group_id} <- fetch_binary(raw, "group_id"),
         {:ok, amount_cents} <- fetch_value(raw, "amount_cents") do
      {:ok, %{group_id: group_id, amount_cents: amount_cents}}
    end
  end

  defp parse_fields("reschedule_group", raw) do
    with {:ok, group_id} <- fetch_binary(raw, "group_id"),
         {:ok, new_arrival_on} <- fetch_binary(raw, "new_arrival_on") do
      {:ok, %{group_id: group_id, new_arrival_on: new_arrival_on}}
    end
  end

  defp parse_fields("cancel_group", raw) do
    with {:ok, group_id} <- fetch_binary(raw, "group_id"),
         {:ok, refund_method} <- fetch_refund_method(raw) do
      {:ok, %{group_id: group_id, refund_method: refund_method}}
    end
  end

  defp parse_fields("apply_hotel_credit", raw) do
    with {:ok, group_id} <- fetch_binary(raw, "group_id"),
         {:ok, amount_cents} <- fetch_value(raw, "amount_cents") do
      {:ok, %{group_id: group_id, amount_cents: amount_cents}}
    end
  end

  defp parse_fields("cancel_rooms", raw) do
    with {:ok, group_id} <- fetch_binary(raw, "group_id"),
         {:ok, room_ids} <- fetch_list(raw, "room_ids"),
         {:ok, refund_method} <- fetch_refund_method(raw) do
      {:ok, %{group_id: group_id, room_ids: room_ids, refund_method: refund_method}}
    end
  end

  defp parse_fields("reduce_cash_payment", raw) do
    with {:ok, payment_operation_id} <- fetch_binary(raw, "payment_operation_id"),
         {:ok, amount_cents} <- fetch_value(raw, "amount_cents") do
      {:ok, %{payment_operation_id: payment_operation_id, amount_cents: amount_cents}}
    end
  end

  defp parse_fields("charge_back_payment", raw) do
    with {:ok, payment_operation_id} <- fetch_binary(raw, "payment_operation_id") do
      {:ok, %{payment_operation_id: payment_operation_id}}
    end
  end

  defp parse_fields("transfer_deposit", raw) do
    with {:ok, source_group_id} <- fetch_binary(raw, "source_group_id"),
         {:ok, destination_group_id} <- fetch_binary(raw, "destination_group_id"),
         {:ok, amount_cents} <- fetch_value(raw, "amount_cents") do
      {:ok,
       %{
         source_group_id: source_group_id,
         destination_group_id: destination_group_id,
         amount_cents: amount_cents,
         destination_expected_revision: Map.get(raw, "destination_expected_revision")
       }}
    end
  end

  defp parse_fields("start_finance_reporting", raw) do
    case fetch_date(raw, "starts_on") do
      {:ok, starts_on} -> {:ok, %{starts_on: starts_on}}
      :error -> {:ok, %{starts_on: :invalid}}
    end
  end

  defp parse_fields("close_finance_period", raw) do
    case fetch_date(raw, "period_end_on") do
      {:ok, period_end_on} -> {:ok, %{period_end_on: period_end_on}}
      :error -> {:ok, %{period_end_on: :invalid}}
    end
  end

  defp fetch_binary(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_date(raw, key) do
    with {:ok, value} <- fetch_binary(raw, key),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp fetch_list(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_value(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp fetch_refund_method(raw) do
    case Map.fetch(raw, "refund_method") do
      :error -> {:ok, "cash"}
      {:ok, method} when method in @refund_methods -> {:ok, method}
      _ -> :error
    end
  end

  defp operation_id_of(raw) when is_map(raw) do
    case Map.get(raw, "operation_id") do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp operation_id_of(_), do: nil

  defp group_id_of(raw) when is_map(raw) do
    case Map.get(raw, "group_id") do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp group_id_of(_), do: nil

  # Applying

  defp apply_op(%{type: "open_group"} = op) do
    with :ok <- reject_existing_group(op.group_id),
         {:ok, stay} <- validate_stay(op.arrival_on, op.departure_on),
         {:ok, rooms} <- validate_rooms(op.rooms),
         :ok <- validate_rate_plan(op.rate_plan),
         {:ok, group} <- insert_group(op, stay, rooms) do
      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, op.group_id, extras)
    end
  end

  defp apply_op(%{type: "record_cash_payment"} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_amount(op.amount_cents),
         :ok <- check_outstanding(group, op.amount_cents),
         {:ok, updated} <- apply_payment(group, op.amount_cents, op.operation_id) do
      Report.posting_date(op.occurred_on)
      |> Report.record_cash(group.property_id, "received", op.amount_cents)

      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: updated.group_id,
        amount_cents: op.amount_cents,
        outstanding_deposit_cents: outstanding_deposit(updated),
        revision: updated.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, op.group_id, extras)
    end
  end

  defp apply_op(%{type: "reschedule_group"} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         {:ok, new_arrival_on} <- validate_new_arrival(op.new_arrival_on, op.occurred_on),
         {:ok, updated} <- apply_reschedule(group, new_arrival_on) do
      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: updated.group_id,
        new_arrival_on: Date.to_iso8601(updated.arrival_on),
        new_departure_on: Date.to_iso8601(updated.departure_on),
        policy_version: Policy.version(updated),
        refundable_until: refundable_until_json(updated),
        revision: updated.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, op.group_id, extras)
    end
  end

  defp apply_op(%{type: "cancel_group"} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- check_refund_method_available(group, op),
         rooms <- active_rooms(group.id),
         {:ok, settlement} <- settle_rooms(group, rooms, op),
         {:ok, updated} <- cancel_rooms_state(group, rooms, settlement, "cancelled") do
      record_settlement_movements(op.occurred_on, group, settlement)

      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: updated.group_id,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: updated.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, op.group_id, extras)
    end
  end

  defp apply_op(%{type: "apply_hotel_credit"} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_amount(op.amount_cents),
         :ok <- check_credit_available(group, op.amount_cents, op.occurred_on),
         :ok <- check_outstanding(group, op.amount_cents),
         {:ok, updated, consumes} <-
           apply_credit(group, op.amount_cents, op.occurred_on, op.operation_id) do
      record_credit_application(op.occurred_on, consumes)

      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: updated.group_id,
        amount_cents: op.amount_cents,
        outstanding_deposit_cents: outstanding_deposit(updated),
        revision: updated.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, op.group_id, extras)
    end
  end

  defp apply_op(%{type: "cancel_rooms"} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         {:ok, rooms} <- fetch_selected_rooms(group, op.room_ids),
         :ok <- check_refund_method_available(group, op),
         {:ok, settlement} <- settle_rooms(group, rooms, op),
         {:ok, updated} <- finish_room_cancellation(group, rooms, settlement) do
      record_settlement_movements(op.occurred_on, group, settlement)

      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: updated.group_id,
        cancelled_room_ids: Enum.map(rooms, & &1.room_id),
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: updated.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, op.group_id, extras)
    end
  end

  defp apply_op(%{type: "reduce_cash_payment"} = op) do
    case fetch_stored_payment(op.payment_operation_id, "payment_not_reducible") do
      {:reject, code, extras} ->
        rejection(op.operation_id, code, nil, extras)

      {:ok, payment} ->
        reduce_payment(op, payment)
    end
  end

  defp apply_op(%{type: "charge_back_payment"} = op) do
    case fetch_stored_payment(op.payment_operation_id, "payment_not_chargeable") do
      {:reject, code, extras} ->
        rejection(op.operation_id, code, nil, extras)

      {:ok, payment} ->
        charge_back_payment(op, payment)
    end
  end

  defp apply_op(%{type: "transfer_deposit"} = op) do
    with {:ok, source} <- fetch_transfer_group(op.source_group_id),
         {:ok, destination} <- fetch_transfer_group(op.destination_group_id),
         :ok <- check_transfer_revision(op.expected_revision, source),
         :ok <- check_transfer_revision(op.destination_expected_revision, destination),
         :ok <- check_transfer_pairs(source, destination),
         :ok <- check_transfer_active(source),
         :ok <- check_transfer_active(destination),
         :ok <- validate_amount(op.amount_cents),
         :ok <- check_held_funding(source, op.amount_cents),
         :ok <- check_transfer_outstanding(destination, op.amount_cents),
         {:ok, source_updated, destination_updated, portions} <-
           apply_transfer(source, destination, op.amount_cents) do
      record_transfer_movements(op.occurred_on, source_updated, destination_updated, portions)

      %{
        operation_id: op.operation_id,
        status: "applied",
        source_group_id: source_updated.group_id,
        destination_group_id: destination_updated.group_id,
        amount_cents: op.amount_cents,
        source_outstanding_deposit_cents: outstanding_deposit(source_updated),
        destination_outstanding_deposit_cents: outstanding_deposit(destination_updated),
        source_revision: source_updated.revision,
        destination_revision: destination_updated.revision
      }
    else
      {:reject, code, extras} -> rejection(op.operation_id, code, nil, extras)
      {:reject, code, group_id, extras} -> rejection(op.operation_id, code, group_id, extras)
    end
  end

  defp apply_op(%{type: "start_finance_reporting", starts_on: :invalid} = op) do
    rejection(op.operation_id, "invalid_reporting_date", nil)
  end

  defp apply_op(%{type: "start_finance_reporting"} = op) do
    if Report.fetch() do
      rejection(op.operation_id, "reporting_already_started", nil)
    else
      case Report.start(op.starts_on, op.operation_id) do
        :ok ->
          %{
            operation_id: op.operation_id,
            status: "applied",
            starts_on: Date.to_iso8601(op.starts_on)
          }

        {:error, :already_started} ->
          rejection(op.operation_id, "reporting_already_started", nil)
      end
    end
  end

  defp apply_op(%{type: "close_finance_period", period_end_on: :invalid} = op) do
    rejection(op.operation_id, "invalid_period", nil)
  end

  defp apply_op(%{type: "close_finance_period"} = op) do
    case Report.close_period(op.period_end_on) do
      :ok ->
        %{
          operation_id: op.operation_id,
          status: "applied",
          period_end_on: Date.to_iso8601(op.period_end_on)
        }

      {:error, :invalid_period} ->
        rejection(op.operation_id, "invalid_period", nil)
    end
  end

  # Shared checks

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:reject, "group_not_found", %{}}
      group -> {:ok, group}
    end
  end

  defp check_expected_revision(%{expected_revision: nil}, _group), do: :ok

  defp check_expected_revision(%{expected_revision: expected}, group) do
    if expected == group.revision do
      :ok
    else
      {:reject, "stale_revision", %{expected_revision: expected, actual_revision: group.revision}}
    end
  end

  defp check_active(%Group{status: "active"}), do: :ok
  defp check_active(_group), do: {:reject, "group_not_active", %{}}

  defp outstanding_deposit(group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  # Opening

  defp reject_existing_group(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:reject, "group_already_exists", %{}}
    else
      :ok
    end
  end

  defp validate_stay(arrival_raw, departure_raw) do
    with {:ok, arrival_on} <- parse_iso_date(arrival_raw),
         {:ok, departure_on} <- parse_iso_date(departure_raw),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, %{arrival_on: arrival_on, departure_on: departure_on, nights: nights}}
    else
      _ -> {:reject, "invalid_stay", %{}}
    end
  end

  defp parse_iso_date(raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_iso_date(_), do: :error

  defp validate_rooms(raw_rooms) do
    with {:ok, rooms} <- parse_rooms(raw_rooms),
         true <- rooms != [],
         true <- unique_room_ids?(rooms) do
      {:ok, rooms}
    else
      _ -> {:reject, "invalid_rooms", %{}}
    end
  end

  defp parse_rooms(raw_rooms) do
    raw_rooms
    |> Enum.reduce_while({:ok, []}, &parse_room/2)
    |> case do
      {:ok, rooms} -> {:ok, Enum.reverse(rooms)}
      {:reject, _, _} = reject -> reject
    end
  end

  defp parse_room(raw, {:ok, acc}) when is_map(raw) do
    with {:ok, room_id} <- fetch_binary(raw, "room_id"),
         {:ok, rate} <- fetch_rate(raw) do
      {:cont, {:ok, [%{room_id: room_id, nightly_rate_cents: rate} | acc]}}
    else
      _ -> {:halt, {:reject, "invalid_rooms", %{}}}
    end
  end

  defp parse_room(_raw, _acc), do: {:halt, {:reject, "invalid_rooms", %{}}}

  defp fetch_rate(raw) do
    case Map.fetch(raw, "nightly_rate_cents") do
      {:ok, rate} when is_integer(rate) and rate >= 0 -> {:ok, rate}
      _ -> :error
    end
  end

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1.room_id)
    length(ids) == length(Enum.uniq(ids))
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans do
      :ok
    else
      {:reject, "invalid_rate_plan", %{}}
    end
  end

  defp insert_group(op, stay, rooms) do
    lodging_total_cents = lodging_total(stay.nights, rooms)
    deposit_due_cents = deposit_due(op.rate_plan, stay.nights, rooms)

    changeset =
      Group.changeset(%Group{}, %{
        group_id: op.group_id,
        guest_id: op.guest_id,
        property_id: op.property_id,
        booked_on: op.occurred_on,
        arrival_on: stay.arrival_on,
        departure_on: stay.departure_on,
        rate_plan: op.rate_plan,
        status: "active",
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        revision: 1
      })

    case Repo.insert(changeset) do
      {:ok, group} ->
        insert_rooms(group, op.rate_plan, stay.nights, rooms)
        {:ok, group}

      {:error, _changeset} ->
        {:reject, "group_already_exists", %{}}
    end
  end

  defp insert_rooms(group, rate_plan, nights, rooms) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          id: Ecto.UUID.generate(),
          group_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          status: "active",
          deposit_due_cents: room_deposit_due(rate_plan, nights, room.nightly_rate_cents),
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Room, rows)
  end

  defp lodging_total(nights, rooms) do
    rooms
    |> Enum.map(&(&1.nightly_rate_cents * nights))
    |> Enum.sum()
  end

  defp deposit_due("advance_purchase", nights, rooms), do: lodging_total(nights, rooms)

  defp deposit_due("flexible", nights, rooms) do
    rooms
    |> Enum.map(fn room ->
      room_deposit_due("flexible", nights, room.nightly_rate_cents)
    end)
    |> Enum.sum()
  end

  defp room_deposit_due("advance_purchase", nights, nightly_rate_cents) do
    nights * nightly_rate_cents
  end

  defp room_deposit_due("flexible", nights, nightly_rate_cents) do
    round_half_up_cents(nightly_rate_cents * nights, @flexible_deposit_percent)
  end

  @doc false
  def round_half_up_cents(amount_cents, percent)
      when is_integer(amount_cents) and amount_cents >= 0 do
    div(amount_cents * percent + 50, 100)
  end

  # Payments

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_amount), do: {:reject, "invalid_amount", %{}}

  defp check_outstanding(group, amount_cents) do
    if amount_cents > outstanding_deposit(group) do
      {:reject, "payment_exceeds_outstanding", %{}}
    else
      :ok
    end
  end

  defp apply_payment(group, amount_cents, operation_id) do
    with :ok <- fill_cash(group, amount_cents, operation_id),
         {:ok, updated} <-
           update_group(group, %{
             deposit_paid_cents: group.deposit_paid_cents + amount_cents,
             cash_paid_cents: group.cash_paid_cents + amount_cents
           }),
         :ok <- Finance.adjust(cash_held_cents: amount_cents) do
      {:ok, updated}
    end
  end

  defp fill_cash(group, amount_cents, operation_id) do
    group.id
    |> active_rooms()
    |> RoomAllocations.fill_cash_rows(amount_cents, operation_id)
    |> RoomAllocations.insert_fill("cash")
  end

  defp active_rooms(group_id) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group_id and r.status == "active",
        order_by: [asc: r.position]
    )
  end

  # Rescheduling

  defp validate_new_arrival(raw, occurred_on) do
    case parse_iso_date(raw) do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          {:ok, new_arrival_on}
        else
          {:reject, "invalid_stay", %{}}
        end

      :error ->
        {:reject, "invalid_stay", %{}}
    end
  end

  defp apply_reschedule(group, new_arrival_on) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    update_group(group, %{
      arrival_on: new_arrival_on,
      departure_on: Date.add(new_arrival_on, nights)
    })
  end

  defp refundable_until_json(group) do
    case Policy.refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  # Cancelling

  defp check_refund_method_available(group, %{refund_method: "hotel_credit"} = op) do
    if Policy.refundable?(group, op.occurred_on) do
      :ok
    else
      {:reject, "refund_method_not_available", %{}}
    end
  end

  defp check_refund_method_available(_group, _op), do: :ok

  defp fetch_selected_rooms(group, room_ids) do
    with true <- room_ids != [],
         true <- Enum.all?(room_ids, &is_binary/1),
         true <- length(Enum.uniq(room_ids)) == length(room_ids) do
      active_by_id =
        for room <- active_rooms(group.id), into: %{}, do: {room.room_id, room}

      selected = Enum.map(room_ids, &Map.get(active_by_id, &1))

      if Enum.any?(selected, &is_nil/1) do
        {:reject, "invalid_rooms", %{}}
      else
        {:ok, Enum.sort_by(selected, & &1.position)}
      end
    else
      _ -> {:reject, "invalid_rooms", %{}}
    end
  end

  defp settle_rooms(group, rooms, op) do
    room_ids = Enum.map(rooms, & &1.id)
    cash_cents = RoomAllocations.held_sum(room_ids, "cash")
    credit_cents = RoomAllocations.held_sum(room_ids, "credit")

    settlement =
      if Policy.refundable?(group, op.occurred_on) do
        settle_rooms_refundable(group, rooms, cash_cents, op)
      else
        settle_rooms_non_refundable(rooms, cash_cents)
      end

    case settlement do
      {:ok, result} ->
        {:ok, Map.merge(result, %{cash_cents: cash_cents, credit_cents: credit_cents})}

      {:reject, _, _} = reject ->
        reject
    end
  end

  defp settle_rooms_refundable(group, rooms, cash_cents, %{refund_method: "hotel_credit"} = op) do
    credit_issued_cents = cash_cents + round_half_up_cents(cash_cents, @credit_bonus_percent)

    with {:ok, lot_id} <-
           Credit.issue_lot(group.guest_id, op.operation_id, credit_issued_cents, op.occurred_on),
         :ok <- RoomAllocations.mark_held(Enum.map(rooms, & &1.id), "cash", "converted", lot_id),
         {:ok, restore_summary} <- Credit.restore_rooms(rooms, op.occurred_on),
         :ok <-
           Finance.adjust(
             cash_held_cents: -cash_cents,
             cash_converted_to_credit_cents: cash_cents
           ) do
      {:ok,
       %{
         refunded_cents: 0,
         retained_cents: 0,
         credit_issued_cents: credit_issued_cents,
         settlement_kind: :converted,
         issued_lot_id: lot_id,
         restore_summary: restore_summary
       }}
    end
  end

  defp settle_rooms_refundable(_group, rooms, cash_cents, op) do
    with :ok <- RoomAllocations.mark_held(Enum.map(rooms, & &1.id), "cash", "refunded"),
         {:ok, restore_summary} <- Credit.restore_rooms(rooms, op.occurred_on),
         :ok <- Finance.adjust(cash_held_cents: -cash_cents, cash_refunded_cents: cash_cents) do
      {:ok,
       %{
         refunded_cents: cash_cents,
         retained_cents: 0,
         credit_issued_cents: 0,
         settlement_kind: :refunded,
         issued_lot_id: nil,
         restore_summary: restore_summary
       }}
    end
  end

  defp settle_rooms_non_refundable(rooms, cash_cents) do
    with :ok <- RoomAllocations.mark_held(Enum.map(rooms, & &1.id), "cash", "retained"),
         :ok <- Credit.consume_rooms(rooms),
         :ok <- Finance.adjust(cash_held_cents: -cash_cents, cash_retained_cents: cash_cents) do
      {:ok,
       %{
         refunded_cents: 0,
         retained_cents: cash_cents,
         credit_issued_cents: 0,
         settlement_kind: :retained,
         issued_lot_id: nil,
         restore_summary: []
       }}
    end
  end

  defp finish_room_cancellation(group, rooms, settlement) do
    cancelled_ids = Enum.map(rooms, & &1.id)

    remaining_active =
      Repo.one(
        from r in Room,
          where: r.group_id == ^group.id and r.status == "active" and r.id not in ^cancelled_ids,
          select: count(r.id)
      )

    status = if remaining_active == 0, do: "cancelled", else: "active"
    cancel_rooms_state(group, rooms, settlement, status)
  end

  defp cancel_rooms_state(group, rooms, settlement, status) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    lodging_cents = Enum.reduce(rooms, 0, &(&1.nightly_rate_cents * nights + &2))
    deposit_due_cents = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))

    mark_rooms_cancelled(rooms)

    update_group(group, %{
      status: status,
      lodging_total_cents: group.lodging_total_cents - lodging_cents,
      deposit_due_cents: group.deposit_due_cents - deposit_due_cents,
      deposit_paid_cents:
        group.deposit_paid_cents - settlement.cash_cents - settlement.credit_cents,
      cash_paid_cents: group.cash_paid_cents - settlement.cash_cents,
      credit_paid_cents: group.credit_paid_cents - settlement.credit_cents
    })
  end

  defp mark_rooms_cancelled(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.update_all(
      from(r in Room, where: r.id in ^room_ids),
      set: [status: "cancelled", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    :ok
  end

  # Applying hotel credit

  defp check_credit_available(group, amount_cents, occurred_on) do
    if Credit.available_cents(group.guest_id, occurred_on) >= amount_cents do
      :ok
    else
      {:reject, "insufficient_credit", %{}}
    end
  end

  defp apply_credit(group, amount_cents, occurred_on, operation_id) do
    rooms = active_rooms(group.id)

    case Credit.apply_to_group(rooms, group.guest_id, amount_cents, occurred_on, operation_id) do
      {:ok, consumes} ->
        case update_group(group, %{
               deposit_paid_cents: group.deposit_paid_cents + amount_cents,
               credit_paid_cents: group.credit_paid_cents + amount_cents
             }) do
          {:ok, updated} -> {:ok, updated, consumes}
          {:error, _changeset} = error -> error
        end

      {:error, :insufficient_credit} ->
        {:reject, "insufficient_credit", %{}}
    end
  end

  # Transferring deposits

  defp fetch_transfer_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:reject, "group_not_found", group_id, %{}}
      group -> {:ok, group}
    end
  end

  defp check_transfer_revision(nil, _group), do: :ok

  defp check_transfer_revision(expected, group) do
    if expected == group.revision do
      :ok
    else
      {:reject, "stale_revision", group.group_id,
       %{expected_revision: expected, actual_revision: group.revision}}
    end
  end

  defp check_transfer_pairs(source, destination) do
    if source.group_id == destination.group_id or source.guest_id != destination.guest_id do
      {:reject, "invalid_transfer", nil, %{}}
    else
      :ok
    end
  end

  defp check_transfer_active(%Group{status: "active"}), do: :ok

  defp check_transfer_active(group) do
    {:reject, "group_not_active", group.group_id, %{}}
  end

  defp check_held_funding(group, amount_cents) do
    room_ids = group.id |> active_rooms() |> Enum.map(& &1.id)

    held_cents =
      RoomAllocations.held_sum(room_ids, "cash") +
        RoomAllocations.held_sum(room_ids, "credit")

    if amount_cents > held_cents do
      {:reject, "transfer_exceeds_held_funding", nil, %{}}
    else
      :ok
    end
  end

  defp check_transfer_outstanding(destination, amount_cents) do
    if amount_cents > outstanding_deposit(destination) do
      {:reject, "transfer_exceeds_outstanding", nil, %{}}
    else
      :ok
    end
  end

  defp apply_transfer(source, destination, amount_cents) do
    source_rooms = active_rooms(source.id)
    destination_rooms = active_rooms(destination.id)

    {:ok, portions} = RoomAllocations.take_held(source_rooms, amount_cents)

    destination_rooms
    |> RoomAllocations.fill_transfer_rows(portions)
    |> insert_transfer_fill()

    :ok = apply_taken_portions(portions)

    cash_moved = portion_total(portions, "cash")
    credit_moved = portion_total(portions, "credit")

    with {:ok, source_updated} <-
           update_group(source, %{
             deposit_paid_cents: source.deposit_paid_cents - amount_cents,
             cash_paid_cents: source.cash_paid_cents - cash_moved,
             credit_paid_cents: source.credit_paid_cents - credit_moved
           }),
         {:ok, destination_updated} <-
           update_group(destination, %{
             deposit_paid_cents: destination.deposit_paid_cents + amount_cents,
             cash_paid_cents: destination.cash_paid_cents + cash_moved,
             credit_paid_cents: destination.credit_paid_cents + credit_moved
           }) do
      {:ok, source_updated, destination_updated, portions}
    end
  end

  defp insert_transfer_fill(rows) do
    {cash_rows, credit_rows} = Enum.split_with(rows, &(&1.kind == "cash"))
    :ok = RoomAllocations.insert_fill(cash_rows, "cash")
    :ok = RoomAllocations.insert_fill(credit_rows, "credit")
  end

  defp apply_taken_portions(portions) do
    portions
    |> Enum.group_by(& &1.room_id)
    |> Enum.each(fn {room_id, taken} ->
      cash_cents = portion_total(taken, "cash")
      credit_cents = portion_total(taken, "credit")

      if cash_cents > 0, do: RoomAllocations.inc_room_paid(room_id, "cash", -cash_cents)

      if credit_cents > 0,
        do: RoomAllocations.inc_room_paid(room_id, "credit", -credit_cents)
    end)

    :ok
  end

  defp portion_total(portions, kind) do
    portions
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end

  # Reducing recorded cash

  defp fetch_stored_payment(payment_operation_id, not_payment_code) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil -> {:reject, "operation_not_found", %{}}
      record -> stored_applied_payment(record, not_payment_code)
    end
  end

  defp stored_applied_payment(%OperationRecord{type: "record_cash_payment"} = record, code) do
    result = Jason.decode!(record.result)

    if result["status"] == "applied" do
      {:ok,
       %{
         operation_id: record.operation_id,
         group_id: result["group_id"],
         amount_cents: result["amount_cents"]
       }}
    else
      {:reject, code, %{}}
    end
  end

  defp stored_applied_payment(_record, code), do: {:reject, code, %{}}

  defp reduce_payment(op, payment) do
    case fetch_group(payment.group_id) do
      {:reject, code, extras} ->
        rejection(op.operation_id, code, payment.group_id, extras)

      {:ok, group} ->
        with :ok <- check_expected_revision(op, group),
             :ok <- check_payment_holds_cash(payment),
             :ok <- validate_amount(op.amount_cents),
             :ok <- check_reduction_held(payment, op.amount_cents),
             {:ok, updated, removed} <- apply_reduction(group, payment, op.amount_cents) do
          record_removed_movements(op.occurred_on, "reduced", removed)

          %{
            operation_id: op.operation_id,
            status: "applied",
            payment_operation_id: payment.operation_id,
            group_id: updated.group_id,
            amount_cents: op.amount_cents,
            outstanding_deposit_cents: outstanding_deposit(updated),
            revision: updated.revision
          }
        else
          {:reject, code, extras} -> rejection(op.operation_id, code, payment.group_id, extras)
        end
    end
  end

  defp check_payment_holds_cash(payment) do
    if held_cash_cents(payment.operation_id) > 0 do
      :ok
    else
      {:reject, "payment_not_reducible", %{}}
    end
  end

  defp held_cash_cents(payment_operation_id) do
    Repo.one(
      from a in RoomAllocation,
        where:
          a.funding_operation_id == ^payment_operation_id and a.kind == "cash" and
            a.status == "held",
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp check_reduction_held(payment, amount_cents) do
    if amount_cents > held_cash_cents(payment.operation_id) do
      {:reject, "reduction_exceeds_held_cash", %{}}
    else
      :ok
    end
  end

  defp apply_reduction(group, payment, amount_cents) do
    {:ok, removed} = RoomAllocations.remove_held(payment.operation_id, amount_cents, "reduced")
    :ok = apply_removed_held(removed)

    :ok =
      Finance.adjust(cash_held_cents: -amount_cents, cash_reduced_cents: amount_cents)

    case settle_removed_groups(group, removed) do
      {:ok, updated} -> {:ok, updated, removed}
      {:error, _changeset} = error -> error
    end
  end

  defp apply_removed_held(removed) do
    removed
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 2))
    |> Enum.each(fn {room_id, amounts} ->
      RoomAllocations.inc_room_paid(room_id, "cash", -Enum.sum(amounts))
    end)

    :ok
  end

  # An applied operation increments the revision of every group whose funding
  # it changes, and always the group it is addressed to.
  defp settle_removed_groups(addressed_group, removed) do
    removed_by_group =
      removed
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
      |> Map.new(fn {group_pk, amounts} -> {group_pk, Enum.sum(amounts)} end)

    for {group_pk, cents} <- removed_by_group, group_pk != addressed_group.id do
      other = Repo.get!(Group, group_pk)

      update_group(other, %{
        deposit_paid_cents: other.deposit_paid_cents - cents,
        cash_paid_cents: other.cash_paid_cents - cents
      })
    end

    own_cents = Map.get(removed_by_group, addressed_group.id, 0)

    update_group(addressed_group, %{
      deposit_paid_cents: addressed_group.deposit_paid_cents - own_cents,
      cash_paid_cents: addressed_group.cash_paid_cents - own_cents
    })
  end

  # Charging back a payment

  defp charge_back_payment(op, payment) do
    case fetch_group(payment.group_id) do
      {:reject, code, extras} ->
        rejection(op.operation_id, code, payment.group_id, extras)

      {:ok, group} ->
        with :ok <- check_expected_revision(op, group),
             {:ok, disposition} <- chargeable_disposition(payment),
             {:ok, updated, chargeback} <- apply_chargeback(group, payment, disposition) do
          record_chargeback_movements(op.occurred_on, chargeback)

          %{
            operation_id: op.operation_id,
            status: "applied",
            payment_operation_id: payment.operation_id,
            group_id: updated.group_id,
            charged_back_cents: disposition.chargeable_cents,
            outstanding_deposit_cents: outstanding_deposit(updated),
            revision: updated.revision
          }
        else
          {:reject, code, extras} -> rejection(op.operation_id, code, payment.group_id, extras)
        end
    end
  end

  defp chargeable_disposition(payment) do
    sums = RoomAllocations.disposition_sums(payment.operation_id)

    held = Map.get(sums, "held", 0)
    refunded = Map.get(sums, "refunded", 0)
    retained = Map.get(sums, "retained", 0)
    converted = Map.get(sums, "converted", 0)
    chargeable_cents = held + refunded + retained + converted

    if chargeable_cents > 0 do
      {:ok,
       %{
         held_cents: held,
         refunded_cents: refunded,
         retained_cents: retained,
         converted_cents: converted,
         chargeable_cents: chargeable_cents
       }}
    else
      {:reject, "payment_not_chargeable", %{}}
    end
  end

  defp apply_chargeback(group, payment, disposition) do
    reclassifications = settled_reclassifications(payment.operation_id)

    {:ok, removed} =
      RoomAllocations.remove_held(payment.operation_id, disposition.held_cents, "charged_back")

    :ok = apply_removed_held(removed)
    revocations = revoke_entitlements(payment.operation_id)

    :ok =
      RoomAllocations.mark_payment(
        payment.operation_id,
        ["refunded", "retained", "converted"],
        "charged_back"
      )

    :ok =
      Finance.adjust(
        cash_held_cents: -disposition.held_cents,
        cash_refunded_cents: -disposition.refunded_cents,
        cash_retained_cents: -disposition.retained_cents,
        cash_converted_to_credit_cents: -disposition.converted_cents,
        cash_charged_back_cents: disposition.chargeable_cents
      )

    case settle_removed_groups(group, removed) do
      {:ok, updated} ->
        {:ok, updated,
         %{removed: removed, reclassifications: reclassifications, revocations: revocations}}

      {:error, _changeset} = error ->
        error
    end
  end

  defp settled_reclassifications(payment_operation_id) do
    Repo.all(
      from a in RoomAllocation,
        join: g in Group,
        on: a.group_id == g.id,
        where:
          a.funding_operation_id == ^payment_operation_id and a.kind == "cash" and
            a.status in ["refunded", "retained", "converted"],
        group_by: [a.status, g.property_id],
        select: %{status: a.status, property_id: g.property_id, amount_cents: sum(a.amount_cents)}
    )
  end

  defp revoke_entitlements(payment_operation_id) do
    lot_ids =
      Repo.all(
        from a in RoomAllocation,
          where:
            a.funding_operation_id == ^payment_operation_id and a.kind == "cash" and
              a.status == "converted",
          distinct: true,
          select: a.lot_id
      )

    Enum.map(lot_ids, &revoke_lot_entitlement(&1, payment_operation_id))
  end

  defp revoke_lot_entitlement(lot_id, payment_operation_id) do
    contributions =
      Repo.all(
        from a in RoomAllocation,
          where:
            a.lot_id == ^lot_id and a.kind == "cash" and
              a.status in ["converted", "charged_back"],
          order_by: [asc: a.id]
      )

    {entitlement_cents, _cumulative} =
      Enum.reduce(contributions, {0, 0}, fn contribution, {entitled, cumulative} ->
        previous_bonus = round_half_up_cents(cumulative, @credit_bonus_percent)
        cumulative = cumulative + contribution.amount_cents
        bonus = round_half_up_cents(cumulative, @credit_bonus_percent) - previous_bonus

        entitled =
          if contribution.funding_operation_id == payment_operation_id do
            entitled + bonus
          else
            entitled
          end

        {entitled, cumulative}
      end)

    lot = Repo.get!(CreditLot, lot_id)
    removed = min(entitlement_cents, lot.remaining_cents)
    unrecovered = entitlement_cents - removed

    Repo.update_all(
      from(l in CreditLot, where: l.id == ^lot_id),
      inc: [remaining_cents: -removed, unrecovered_clawback_cents: unrecovered]
    )

    {lot_id, removed}
  end

  # Reporting movements

  defp record_settlement_movements(occurred_on, group, settlement) do
    posting_date = Report.posting_date(occurred_on)
    record_settlement_cash(posting_date, group.property_id, settlement)

    Enum.each(settlement.restore_summary, fn summary ->
      Report.record_credit(posting_date, "absorbed", summary.absorbed, summary.lot_id)
      Report.record_credit(posting_date, "expired", summary.expired, summary.lot_id)
      Report.record_credit(posting_date, "restored", summary.restored, summary.lot_id)
    end)
  end

  defp record_settlement_cash(posting_date, property_id, %{settlement_kind: :refunded} = s) do
    Report.record_cash(posting_date, property_id, "refunded", s.cash_cents)
  end

  defp record_settlement_cash(posting_date, property_id, %{settlement_kind: :converted} = s) do
    Report.record_cash(posting_date, property_id, "converted_to_credit", s.cash_cents)
    Report.record_credit(posting_date, "issued", s.credit_issued_cents, s.issued_lot_id)
  end

  defp record_settlement_cash(posting_date, property_id, %{settlement_kind: :retained} = s) do
    Report.record_cash(posting_date, property_id, "retained", s.cash_cents)
    Report.record_credit(posting_date, "consumed", s.credit_cents, nil)
  end

  defp record_credit_application(occurred_on, consumes) do
    posting_date = Report.posting_date(occurred_on)

    Enum.each(consumes, fn {lot, taken} ->
      Report.record_credit(posting_date, "applied", -taken, lot.id)
    end)
  end

  defp record_transfer_movements(occurred_on, source, destination, portions) do
    posting_date = Report.posting_date(occurred_on)
    cash_cents = portion_total(portions, "cash")
    Report.record_cash(posting_date, source.property_id, "transferred_out", cash_cents)
    Report.record_cash(posting_date, destination.property_id, "transferred_in", cash_cents)
  end

  # Removed held cash is reported on the property where it was held, which is
  # where the cash settles for reductions and chargebacks.
  defp record_removed_movements(occurred_on, entry, removed) do
    posting_date = Report.posting_date(occurred_on)
    record_removed_on(posting_date, entry, removed)
  end

  defp record_removed_on(nil, _entry, _removed), do: :ok

  defp record_removed_on(posting_date, entry, removed) do
    removed
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
    |> Enum.each(fn {group_pk, amounts} ->
      group = Repo.get!(Group, group_pk)
      Report.record_cash(posting_date, group.property_id, entry, Enum.sum(amounts))
    end)

    :ok
  end

  defp record_chargeback_movements(occurred_on, chargeback) do
    posting_date = Report.posting_date(occurred_on)
    record_removed_on(posting_date, "charged_back", chargeback.removed)
    record_reclassifications(posting_date, chargeback.reclassifications)

    Enum.each(chargeback.revocations, fn {lot_id, removed} ->
      Report.record_credit(posting_date, "revoked", -removed, lot_id)
    end)
  end

  # Reclassified settled cash is reported as a negative movement in its
  # original entry together with a positive charged-back movement on the
  # property where it was settled.
  defp record_reclassifications(nil, _reclassifications), do: :ok

  defp record_reclassifications(posting_date, reclassifications) do
    charged_back_by_property =
      Enum.reduce(reclassifications, %{}, fn row, acc ->
        Report.record_cash(
          posting_date,
          row.property_id,
          reclassification_entry(row.status),
          -row.amount_cents
        )

        Map.update(acc, row.property_id, row.amount_cents, &(&1 + row.amount_cents))
      end)

    Enum.each(charged_back_by_property, fn {property_id, cents} ->
      Report.record_cash(posting_date, property_id, "charged_back", cents)
    end)

    :ok
  end

  defp reclassification_entry("refunded"), do: "refunded"
  defp reclassification_entry("retained"), do: "retained"
  defp reclassification_entry("converted"), do: "converted_to_credit"

  # Persistence helpers

  defp update_group(%Group{} = group, changes) do
    group
    |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
    |> Repo.update()
  end

  # Results

  defp rejection(operation_id, code, group_id, extras \\ %{}) do
    %{operation_id: operation_id, status: "rejected", code: code}
    |> maybe_put_group_id(group_id)
    |> Map.merge(extras)
  end

  defp maybe_put_group_id(result, group_id) when is_binary(group_id) do
    Map.put(result, :group_id, group_id)
  end

  defp maybe_put_group_id(result, _group_id), do: result
end
