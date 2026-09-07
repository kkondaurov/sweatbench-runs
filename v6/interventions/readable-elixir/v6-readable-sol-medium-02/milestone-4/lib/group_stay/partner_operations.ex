defmodule GroupStay.PartnerOperations do
  @moduledoc """
  Applies partner operations one at a time and remembers their results durably.

  Each call owns a database transaction. `process_batch/1` deliberately performs calls in list
  order, so later operations observe earlier commits. Domain work happens within an explicit
  SQLite savepoint: handled rejection rolls back that work but is committed to the operation
  record, while an unexpected exception rolls back both and aborts the request.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.HotelCredit
  alias GroupStay.Repo
  alias GroupStay.Reservations
  alias GroupStay.RoomAccounting
  alias GroupStay.PartnerOperations.OperationRecord

  alias GroupStay.Reservations.{
    CancellationPolicy,
    CashPaymentAccounting,
    GroupReservation,
    Room
  }

  @rate_plans ~w(flexible advance_purchase)

  @doc "Processes a syntactically valid operation array in order."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Returns the exact result stored for an operation identifier."
  def get_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, record.result}
    end
  end

  def get_result(_operation_id), do: {:error, :operation_not_found}

  @doc "Returns the current disposition statement for a durable cash payment."
  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      _record ->
        case Repo.get_by(CashPaymentAccounting, payment_operation_id: payment_operation_id) do
          nil -> {:error, :payment_not_reconcilable}
          payment -> {:ok, payment_statement(payment)}
        end
    end
  end

  def get_payment(_payment_operation_id), do: {:error, :operation_not_found}

  defp process_operation(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) and operation_id != "" do
    # Taking SQLite's write reservation before reading the operation record serializes concurrent
    # first attempts. A waiter can only proceed after it can observe the winner's commit.
    {:ok, result} =
      Repo.transaction(fn -> process_idempotently(operation_id, operation) end, mode: :immediate)

    result
  end

  defp process_operation(operation) when is_map(operation) do
    rejected_result(Map.get(operation, "operation_id"), :invalid_operation)
  end

  defp process_operation(_operation), do: rejected_result(nil, :invalid_operation)

  defp process_idempotently(operation_id, operation) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> process_first_attempt(operation_id, operation)
      record -> replay_or_reject(record, operation)
    end
  end

  defp process_first_attempt(operation_id, operation) do
    result =
      operation
      |> first_attempt_result(operation_id)
      |> normalize_json()

    now = DateTime.utc_now(:second)

    record =
      %OperationRecord{
        operation_id: operation_id,
        operation_type: submitted_type(operation),
        submission: operation,
        result: result,
        inserted_at: now,
        updated_at: now
      }
      |> Repo.insert!()

    if submitted_type(operation) == "record_cash_payment" and result["status"] == "applied" do
      RoomAccounting.bind_operation_record(operation_id, record.id)
    end

    result
  end

  defp first_attempt_result(operation, operation_id) do
    case validate_common_fields(operation) do
      :ok ->
        case process_domain_operation(operation) do
          {:ok, domain_result} -> applied_result(operation_id, domain_result)
          {:error, reason} -> rejected_result(operation_id, reason)
        end

      {:error, reason} ->
        rejected_result(operation_id, reason)
    end
  end

  defp replay_or_reject(%OperationRecord{submission: submission, result: result}, operation) do
    if submission === operation do
      result
    else
      rejected_result(operation["operation_id"], :operation_id_conflict)
    end
  end

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_operation), do: nil

  # Results cross a JSON API boundary. Normalizing before both storage and return keeps the first
  # response byte-for-byte equivalent at the JSON-value level to later database-backed replays.
  defp normalize_json(value), do: value |> Jason.encode!() |> Jason.decode!()

  # Ecto treats nested transactions as part of their parent transaction. An explicit savepoint is
  # therefore used so the domain layer can reject after making writes without poisoning the outer
  # transaction that must retain the rejection result.
  defp process_domain_operation(operation) do
    Repo.query!("SAVEPOINT partner_domain_operation")

    try do
      result = dispatch(operation)
      Repo.query!("RELEASE SAVEPOINT partner_domain_operation")
      {:ok, result}
    catch
      {:partner_operation_rejected, reason} ->
        Repo.query!("ROLLBACK TO SAVEPOINT partner_domain_operation")
        Repo.query!("RELEASE SAVEPOINT partner_domain_operation")
        {:error, reason}
    end
  end

  defp reject(reason), do: throw({:partner_operation_rejected, reason})

  defp validate_common_fields(%{
         "operation_id" => operation_id,
         "type" => type,
         "occurred_on" => occurred_on
       })
       when is_binary(operation_id) and operation_id != "" and is_binary(type) and
              is_binary(occurred_on) do
    case Date.from_iso8601(occurred_on) do
      {:ok, _date} -> :ok
      _ -> {:error, :invalid_operation}
    end
  end

  defp validate_common_fields(_operation), do: {:error, :invalid_operation}

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp dispatch(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)
  defp dispatch(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)
  defp dispatch(%{"type" => "cancel_rooms"} = operation), do: cancel_rooms(operation)

  defp dispatch(%{"type" => "reduce_cash_payment"} = operation),
    do: reduce_cash_payment(operation)

  defp dispatch(%{"type" => "charge_back_payment"} = operation),
    do: charge_back_payment(operation)

  defp dispatch(_operation), do: reject(:invalid_operation)

  defp open_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         :ok <- ensure_group_is_new(group_id),
         {:ok, attributes} <- validate_open_group(operation, group_id) do
      group =
        %GroupReservation{}
        |> Changeset.change(attributes)
        |> Changeset.unique_constraint(:group_id)
        |> Repo.insert()
        |> case do
          {:ok, group} -> group
          {:error, _changeset} -> reject(:group_already_exists)
        end

      rooms =
        operation["rooms"]
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          now = DateTime.utc_now(:second)

          %{
            group_id: group.group_id,
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            position: position,
            status: "active",
            lodging_total_cents:
              room["nightly_rate_cents"] * Date.diff(group.departure_on, group.arrival_on),
            deposit_due_cents:
              room_deposit(
                room["nightly_rate_cents"],
                Date.diff(group.departure_on, group.arrival_on),
                group.rate_plan
              ),
            cash_paid_cents: 0,
            credit_paid_cents: 0,
            inserted_at: now,
            updated_at: now
          }
        end)

      {_count, nil} = Repo.insert_all(Room, rooms)

      %{
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:error, reason} -> reject(reason)
    end
  end

  defp validate_open_group(operation, group_id) do
    required = ~w(guest_id property_id arrival_on departure_on rate_plan rooms)

    if Enum.any?(required, &(not Map.has_key?(operation, &1))) do
      {:error, :invalid_operation}
    else
      with {:ok, guest_id} <- identifier(operation["guest_id"]),
           {:ok, property_id} <- identifier(operation["property_id"]),
           {:ok, booked_on} <- parse_date(operation["occurred_on"], :invalid_operation),
           {:ok, arrival_on, departure_on, nights} <- validate_stay(operation),
           {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]),
           {:ok, rooms} <- validate_rooms(operation["rooms"]) do
        lodging_total = Enum.sum_by(rooms, &(&1["nightly_rate_cents"] * nights))
        deposit_due = calculate_deposit(rooms, nights, rate_plan)

        {:ok,
         %{
           group_id: group_id,
           guest_id: guest_id,
           property_id: property_id,
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: rate_plan,
           policy_version: CancellationPolicy.version(rate_plan, booked_on),
           status: "active",
           lodging_total_cents: lodging_total,
           deposit_due_cents: deposit_due,
           deposit_paid_cents: 0,
           cash_paid_cents: 0,
           credit_paid_cents: 0,
           cash_refunded_cents: 0,
           cash_retained_cents: 0,
           cash_converted_to_credit_cents: 0,
           revision: 1
         }}
      end
    end
  end

  defp validate_stay(%{"arrival_on" => arrival, "departure_on" => departure}) do
    with {:ok, arrival_on} <- parse_date(arrival, :invalid_stay),
         {:ok, departure_on} <- parse_date(departure, :invalid_stay),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 ->
          true

        _room ->
          false
      end)

    if valid? do
      room_ids = Enum.map(rooms, &Map.fetch!(&1, "room_id"))

      if Enum.uniq(room_ids) == room_ids,
        do: {:ok, rooms},
        else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp calculate_deposit(rooms, nights, "advance_purchase") do
    Enum.sum_by(rooms, &(&1["nightly_rate_cents"] * nights))
  end

  defp calculate_deposit(rooms, nights, "flexible") do
    Enum.sum_by(rooms, fn room ->
      lodging_amount = room["nightly_rate_cents"] * nights
      div(lodging_amount * 20 + 50, 100)
    end)
  end

  defp room_deposit(rate, nights, "advance_purchase"), do: rate * nights
  defp room_deposit(rate, nights, "flexible"), do: div(rate * nights * 20 + 50, 100)

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- validate_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, amount} <- validate_amount(operation),
         outstanding = Reservations.outstanding_deposit(group),
         :ok <- ensure_payment_within_outstanding(amount, outstanding),
         _payment <-
           RoomAccounting.record_cash_payment(group, operation["operation_id"], amount),
         {:ok, updated} <-
           update_group(group,
             deposit_paid_cents: group.deposit_paid_cents + amount,
             cash_paid_cents: group.cash_paid_cents + amount
           ) do
      %{
        group_id: group_id,
        amount_cents: amount,
        outstanding_deposit_cents: Reservations.outstanding_deposit(updated),
        revision: updated.revision
      }
    else
      {:error, reason} -> reject(reason)
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- validate_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, amount} <- validate_amount(operation),
         outstanding = Reservations.outstanding_deposit(group),
         :ok <- ensure_payment_within_outstanding(amount, outstanding),
         :ok <- HotelCredit.allocate(group.guest_id, group_id, amount, occurred_on),
         {:ok, updated} <-
           update_group(group,
             deposit_paid_cents: group.deposit_paid_cents + amount,
             credit_paid_cents: group.credit_paid_cents + amount
           ) do
      %{
        group_id: group_id,
        amount_cents: amount,
        outstanding_deposit_cents: Reservations.outstanding_deposit(updated),
        revision: updated.revision
      }
    else
      {:error, reason} -> reject(reason)
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- validate_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, new_arrival} <- reschedule_date(operation, occurred_on),
         shift = Date.diff(new_arrival, group.arrival_on),
         new_departure = Date.add(group.departure_on, shift),
         {:ok, updated} <-
           update_group(group, arrival_on: new_arrival, departure_on: new_departure) do
      %{
        group_id: group_id,
        new_arrival_on: updated.arrival_on,
        new_departure_on: updated.departure_on,
        policy_version: CancellationPolicy.version(updated),
        refundable_until: CancellationPolicy.refundable_until(updated),
        revision: updated.revision
      }
    else
      {:error, reason} -> reject(reason)
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- validate_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, refund_method} <- validate_refund_method(operation),
         refundable? = CancellationPolicy.refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(refund_method, refundable?) do
      rooms = active_rooms(group_id)

      settlement =
        RoomAccounting.settle_rooms(
          group,
          rooms,
          refundable?,
          refund_method,
          operation["operation_id"],
          occurred_on
        )

      {:ok, updated} = update_after_settlement(group, settlement)

      %{
        group_id: group_id,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: updated.revision
      }
    else
      {:error, reason} -> reject(reason)
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- validate_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, room_ids} <- required_room_ids(operation),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, refund_method} <- validate_refund_method(operation),
         refundable? = CancellationPolicy.refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(refund_method, refundable?),
         {:ok, rooms} <- selected_rooms(group_id, room_ids) do
      settlement =
        RoomAccounting.settle_rooms(
          group,
          rooms,
          refundable?,
          refund_method,
          operation["operation_id"],
          occurred_on
        )

      {:ok, updated} = update_after_settlement(group, settlement)

      %{
        group_id: group_id,
        cancelled_room_ids: Enum.map(rooms, & &1.room_id),
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: updated.revision
      }
    else
      {:error, reason} -> reject(reason)
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, payment_operation_id} <- required_identifier(operation, "payment_operation_id"),
         {:ok, payment} <- fetch_payment_target(payment_operation_id, :payment_not_reducible),
         {:ok, group} <- fetch_group(payment.group_id),
         :ok <- validate_expected_revision(operation, group),
         :ok <- ensure_reducible(payment),
         {:ok, amount} <- validate_amount(operation),
         :ok <- ensure_reduction_within_held(amount, payment.held_cents) do
      totals = RoomAccounting.reduce_payment(payment, amount)

      {:ok, updated} =
        update_group(group,
          cash_paid_cents: totals.cash_paid_cents,
          deposit_paid_cents: totals.deposit_paid_cents,
          cash_reduced_cents: group.cash_reduced_cents + amount
        )

      %{
        payment_operation_id: payment_operation_id,
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: Reservations.outstanding_deposit(updated),
        revision: updated.revision
      }
    else
      {:error, reason} -> reject(reason)
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, payment_operation_id} <- required_identifier(operation, "payment_operation_id"),
         {:ok, payment} <- fetch_payment_target(payment_operation_id, :payment_not_chargeable),
         {:ok, group} <- fetch_group(payment.group_id),
         :ok <- validate_expected_revision(operation, group),
         :ok <- ensure_chargeable(payment) do
      {charged, totals} = RoomAccounting.charge_back_payment(payment)

      {:ok, updated} =
        update_group(group,
          cash_paid_cents: totals.cash_paid_cents,
          deposit_paid_cents: totals.deposit_paid_cents,
          cash_refunded_cents: group.cash_refunded_cents - payment.refunded_cents,
          cash_retained_cents: group.cash_retained_cents - payment.retained_cents,
          cash_converted_to_credit_cents:
            group.cash_converted_to_credit_cents - payment.converted_to_credit_cents,
          cash_charged_back_cents: group.cash_charged_back_cents + charged
        )

      %{
        payment_operation_id: payment_operation_id,
        group_id: group.group_id,
        charged_back_cents: charged,
        outstanding_deposit_cents: Reservations.outstanding_deposit(updated),
        revision: updated.revision
      }
    else
      {:error, reason} -> reject(reason)
    end
  end

  defp required_identifier(operation, key) do
    if Map.has_key?(operation, key),
      do: identifier(operation[key]),
      else: {:error, :invalid_operation}
  end

  defp identifier(value) when is_binary(value) and value != "", do: {:ok, value}
  defp identifier(_value), do: {:error, :invalid_operation}

  defp ensure_group_is_new(group_id) do
    if Repo.exists?(from group in GroupReservation, where: group.group_id == ^group_id),
      do: {:error, :group_already_exists},
      else: :ok
  end

  defp fetch_group(group_id) do
    case Repo.get(GroupReservation, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp validate_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected == group.revision ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        {:error,
         {:stale_revision,
          %{
            group_id: group.group_id,
            expected_revision: expected,
            actual_revision: group.revision
          }}}

      {:ok, _invalid} ->
        {:error, :invalid_operation}
    end
  end

  defp ensure_active(%GroupReservation{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, :group_not_active}

  defp validate_refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ~w(cash hotel_credit) -> {:ok, method}
      _invalid -> {:error, :invalid_refund_method}
    end
  end

  defp ensure_refund_method_available("hotel_credit", false),
    do: {:error, :refund_method_not_available}

  defp ensure_refund_method_available(_method, _refundable?), do: :ok

  defp validate_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, :invalid_amount}
      :error -> {:error, :invalid_operation}
    end
  end

  defp ensure_payment_within_outstanding(amount, outstanding) when amount <= outstanding, do: :ok

  defp ensure_payment_within_outstanding(_amount, _outstanding),
    do: {:error, :payment_exceeds_outstanding}

  defp fetch_payment_target(payment_operation_id, invalid_target_error) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      _record ->
        case Repo.get_by(CashPaymentAccounting, payment_operation_id: payment_operation_id) do
          nil -> {:error, invalid_target_error}
          payment -> {:ok, payment}
        end
    end
  end

  defp ensure_reducible(%CashPaymentAccounting{held_cents: held}) when held > 0, do: :ok
  defp ensure_reducible(_payment), do: {:error, :payment_not_reducible}

  defp ensure_reduction_within_held(amount, held) when amount <= held, do: :ok

  defp ensure_reduction_within_held(_amount, _held),
    do: {:error, :reduction_exceeds_held_cash}

  defp ensure_chargeable(%CashPaymentAccounting{} = payment) do
    remaining = payment.recorded_cents - payment.reduced_cents

    if remaining > 0 and payment.charged_back_cents == 0,
      do: :ok,
      else: {:error, :payment_not_chargeable}
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: [asc: room.position]
    )
  end

  defp selected_rooms(group_id, room_ids) when is_list(room_ids) and room_ids != [] do
    valid_identifiers? =
      Enum.all?(room_ids, &(is_binary(&1) and &1 != "")) and Enum.uniq(room_ids) == room_ids

    if valid_identifiers? do
      requested = MapSet.new(room_ids)
      rooms = Enum.filter(active_rooms(group_id), &MapSet.member?(requested, &1.room_id))

      if length(rooms) == length(room_ids), do: {:ok, rooms}, else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp selected_rooms(_group_id, _room_ids), do: {:error, :invalid_rooms}

  defp required_room_ids(operation) do
    case Map.fetch(operation, "room_ids") do
      {:ok, room_ids} -> {:ok, room_ids}
      :error -> {:error, :invalid_operation}
    end
  end

  defp update_after_settlement(group, settlement) do
    totals = settlement.active_totals

    update_group(group,
      status: if(totals.active_room_count == 0, do: "cancelled", else: "active"),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      cash_refunded_cents: group.cash_refunded_cents + settlement.refunded_cents,
      cash_retained_cents: group.cash_retained_cents + settlement.retained_cents,
      cash_converted_to_credit_cents:
        group.cash_converted_to_credit_cents + settlement.converted_cents
    )
  end

  defp payment_statement(payment) do
    %{
      payment_operation_id: payment.payment_operation_id,
      original_group_id: payment.group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: payment.held_cents,
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_to_credit_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }
  end

  defp reschedule_date(operation, occurred_on) do
    case Map.fetch(operation, "new_arrival_on") do
      {:ok, value} ->
        with {:ok, date} <- parse_date(value, :invalid_stay),
             true <- Date.after?(date, occurred_on) do
          {:ok, date}
        else
          _ -> {:error, :invalid_stay}
        end

      :error ->
        {:error, :invalid_operation}
    end
  end

  defp parse_date(value, error) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, error}
    end
  end

  defp parse_date(_value, error), do: {:error, error}

  defp update_group(group, attributes) do
    now = DateTime.utc_now(:second)

    query =
      from candidate in GroupReservation,
        where: candidate.group_id == ^group.group_id and candidate.revision == ^group.revision

    updates = [revision: group.revision + 1, updated_at: now] ++ attributes

    case Repo.update_all(query, set: updates) do
      {1, nil} ->
        {:ok, Repo.get!(GroupReservation, group.group_id)}

      {0, nil} ->
        actual = Repo.get!(GroupReservation, group.group_id).revision

        {:error,
         {:stale_revision,
          %{group_id: group.group_id, expected_revision: group.revision, actual_revision: actual}}}
    end
  end

  defp applied_result(operation_id, result) do
    result
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, "applied")
  end

  defp rejected_result(operation_id, {:stale_revision, details}) do
    details
    |> Map.merge(%{operation_id: operation_id, status: "rejected", code: "stale_revision"})
  end

  defp rejected_result(operation_id, reason) when is_atom(reason) do
    %{operation_id: operation_id, status: "rejected", code: Atom.to_string(reason)}
  end
end
