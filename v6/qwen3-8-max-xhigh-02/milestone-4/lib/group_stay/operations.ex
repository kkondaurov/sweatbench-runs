defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in batch order.

  Every operation runs in its own transaction. An operation with a usable
  `operation_id` is durably idempotent: its result is committed together
  with an idempotency record in the same transaction, a retry with an
  equivalent payload returns the stored result, and a reused identifier
  with a different payload is rejected with `operation_id_conflict`. A
  handled rejection leaves domain state unchanged but commits its
  idempotency record; processing then continues with the next operation.
  An unexpected exception rolls the operation back, is not remembered, and
  aborts the batch. An operation observes changes made by earlier
  operations in the same batch.

  Cash and credit fund active room deposits in the rooms' original order,
  filling one room's deposit before moving to the next; room allocations
  record the fill so settlements, reductions, and chargebacks can move the
  held amounts without changing any other funding.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Groups

  alias GroupStay.Groups.{
    CashPayment,
    CreditApplication,
    CreditLot,
    CreditLotContribution,
    Group,
    Room,
    RoomAllocation
  }

  alias GroupStay.Operations.{Idempotency, OperationRecord}
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  @credit_validity_days 365
  @max_attempts 3

  @doc """
  Applies each operation in order and returns one result per operation.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Returns the result remembered for the given operation identifier, or
  `nil` when nothing was remembered under it.
  """
  def get_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      %OperationRecord{result: result} -> result
    end
  end

  @doc """
  Reconciles one durably recorded, applied cash payment: the current
  disposition of that payment's recorded cash. Reading a statement never
  changes state.
  """
  def reconcile_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      %OperationRecord{type: "record_cash_payment", result: %{"status" => "applied"}} ->
        case Repo.get_by(CashPayment, operation_id: payment_operation_id) do
          nil ->
            {:error, :not_reconcilable}

          payment ->
            group = Repo.get!(Group, payment.group_id)

            {:ok,
             %{
               "payment_operation_id" => payment_operation_id,
               "original_group_id" => group.group_id,
               "recorded_cents" => payment.amount_cents,
               "held_cents" => held_cents(payment),
               "refunded_cents" => payment.refunded_cents,
               "retained_cents" => payment.retained_cents,
               "converted_to_credit_cents" => payment.converted_cents,
               "reduced_cents" => payment.reduced_cents,
               "charged_back_cents" => payment.charged_back_cents
             }}
        end

      _other ->
        {:error, :not_reconcilable}
    end
  end

  # Each operation gets its own transaction. An operation with a usable
  # identifier also commits its idempotency record there; a handled
  # rejection commits the record without changing domain state.
  defp apply_operation(op) do
    case idempotency_key(op) do
      nil -> run(fn -> process_once(op) end)
      operation_id -> Idempotency.process(operation_id, op, fn -> process_once(op) end)
    end
  end

  # Only a non-empty string identifier can anchor an idempotency record;
  # anything else is processed without being remembered.
  defp idempotency_key(op) when is_map(op) do
    case Map.get(op, "operation_id") do
      key when is_binary(key) and key != "" -> key
      _other -> nil
    end
  end

  defp idempotency_key(_other), do: nil

  defp process_once(%{"type" => "open_group"} = op), do: open_group(op)

  defp process_once(%{"type" => "record_cash_payment"} = op), do: record_cash_payment(op)

  defp process_once(%{"type" => "reschedule_group"} = op), do: reschedule_group(op)

  defp process_once(%{"type" => "cancel_group"} = op), do: cancel_group(op)

  defp process_once(%{"type" => "cancel_rooms"} = op), do: cancel_rooms(op)

  defp process_once(%{"type" => "apply_hotel_credit"} = op), do: apply_hotel_credit(op)

  defp process_once(%{"type" => "reduce_cash_payment"} = op), do: reduce_cash_payment(op)

  defp process_once(%{"type" => "charge_back_payment"} = op), do: charge_back_payment(op)

  defp process_once(op) when is_map(op),
    do: rejected(Map.get(op, "operation_id"), "invalid_operation")

  defp process_once(_other), do: rejected(nil, "invalid_operation")

  # A rejection performs no domain writes, so committing it leaves the
  # domain unchanged. A concurrent writer can trip the revision guard; the
  # operation is then retried against fresh state.
  defp run(fun, attempt \\ 1) do
    case Repo.transaction(fun) do
      {:ok, result} ->
        result

      {:error, :stale_group} when attempt < @max_attempts ->
        run(fun, attempt + 1)

      {:error, reason} ->
        raise "operation could not be applied: #{inspect(reason)}"
    end
  end

  ## open_group

  defp open_group(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, guest_id} <- fetch_string(op, "guest_id"),
         {:ok, property_id} <- fetch_string(op, "property_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, arrival_on} <- fetch_date(op, "arrival_on"),
         {:ok, departure_on} <- fetch_date(op, "departure_on"),
         {:ok, rate_plan} <- fetch_string(op, "rate_plan"),
         {:ok, rooms} <- fetch_rooms(op),
         :ok <- ensure_group_absent(group_id),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rooms(rooms),
         :ok <- validate_rate_plan(rate_plan) do
      create_group(op_id, %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        occurred_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      })
    else
      {:error, code} -> rejected(Map.get(op, "operation_id"), code)
    end
  end

  defp ensure_group_absent(group_id) do
    if Repo.get_by(Group, group_id: group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rooms(rooms) do
    cond do
      rooms == [] ->
        {:error, "invalid_rooms"}

      Enum.any?(rooms, &invalid_room?/1) ->
        {:error, "invalid_rooms"}

      length(Enum.uniq_by(rooms, & &1["room_id"])) != length(rooms) ->
        {:error, "invalid_rooms"}

      true ->
        :ok
    end
  end

  defp invalid_room?(room) when not is_map(room), do: true

  defp invalid_room?(room) do
    not valid_identifier?(room["room_id"]) or not positive_integer?(room["nightly_rate_cents"])
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans do
      :ok
    else
      {:error, "invalid_rate_plan"}
    end
  end

  defp create_group(op_id, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    rooms =
      Enum.map(attrs.rooms, fn room ->
        nightly_rate_cents = room["nightly_rate_cents"]
        lodging_cents = nights * nightly_rate_cents

        %{
          room_id: room["room_id"],
          nightly_rate_cents: nightly_rate_cents,
          lodging_cents: lodging_cents,
          deposit_cents: room_deposit(lodging_cents, attrs.rate_plan)
        }
      end)

    lodging_total_cents = rooms |> Enum.map(& &1.lodging_cents) |> Enum.sum()
    deposit_due_cents = rooms |> Enum.map(& &1.deposit_cents) |> Enum.sum()

    changeset =
      %Group{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        arrival_on: attrs.arrival_on,
        departure_on: attrs.departure_on,
        booked_on: attrs.occurred_on,
        rate_plan: attrs.rate_plan,
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        rooms:
          rooms
          |> Enum.with_index()
          |> Enum.map(fn {room, position} ->
            %Room{
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: position,
              lodging_cents: room.lodging_cents,
              deposit_cents: room.deposit_cents
            }
          end)
      }
      |> Changeset.change()
      |> Changeset.unique_constraint(:group_id)

    case Repo.insert(changeset) do
      {:ok, group} ->
        applied(op_id, %{
          "group_id" => group.group_id,
          "deposit_due_cents" => deposit_due_cents,
          "revision" => group.revision
        })

      {:error, _changeset} ->
        rejected(op_id, "group_already_exists")
    end
  end

  # Flexible rooms deposit a percentage of their own lodging amount, rounded
  # per room; advance-purchase rooms deposit their full lodging amount.
  defp room_deposit(lodging_cents, "flexible") do
    round_half_up(lodging_cents * @flexible_deposit_percent, 100)
  end

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  # Rounds numerator / denominator to the nearest integer; an exact half
  # rounds upward.
  defp round_half_up(numerator, denominator) do
    div(2 * numerator + denominator, 2 * denominator)
  end

  ## record_cash_payment

  defp record_cash_payment(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, amount_cents} <- fetch_present(op, "amount_cents"),
         {:ok, group} <- fetch_group_with_rooms(group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_amount(amount_cents),
         :ok <- validate_outstanding(group, amount_cents) do
      apply_payment(op_id, group, amount_cents, occurred_on)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  defp validate_amount(amount_cents) do
    if positive_integer?(amount_cents) do
      :ok
    else
      {:error, "invalid_amount"}
    end
  end

  defp validate_outstanding(group, amount_cents) do
    if amount_cents <= Groups.outstanding_deposit_cents(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp apply_payment(op_id, group, amount_cents, occurred_on) do
    payment =
      Repo.insert!(%CashPayment{
        group_id: group.id,
        amount_cents: amount_cents,
        occurred_on: occurred_on,
        operation_id: stored_operation_id(op_id)
      })

    allocate_funding(group.rooms, :cash, payment.id, amount_cents)

    group = bump_group!(group, deposit_paid_cents: group.deposit_paid_cents + amount_cents)

    applied(op_id, %{
      "group_id" => group.group_id,
      "amount_cents" => amount_cents,
      "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
      "revision" => group.revision
    })
  end

  # Cash and credit fund active room deposits in the rooms' original order,
  # filling one room's deposit before moving to the next. New funding
  # operations allocate in operation-processing order, after all funding
  # already held. Returns the rooms with the new funding applied so later
  # allocations in the same operation observe it.
  defp allocate_funding(rooms, kind, source_pk, amount_cents) do
    takes =
      rooms
      |> Enum.filter(&(&1.status == "active"))
      |> fill_rooms(amount_cents)

    Enum.each(takes, fn {room, take} ->
      Repo.insert!(allocation(kind, room.id, source_pk, take))

      Repo.update_all(
        from(r in Room, where: r.id == ^room.id),
        inc: [{paid_field(kind), take}]
      )
    end)

    taken_by_room = Map.new(takes, fn {room, take} -> {room.id, take} end)

    Enum.map(rooms, fn room ->
      case Map.get(taken_by_room, room.id, 0) do
        0 ->
          room

        take ->
          case kind do
            :cash -> %{room | cash_paid_cents: room.cash_paid_cents + take}
            :credit -> %{room | credit_paid_cents: room.credit_paid_cents + take}
          end
      end
    end)
  end

  defp allocation(:cash, room_pk, payment_pk, amount_cents) do
    %RoomAllocation{room_id: room_pk, cash_payment_id: payment_pk, amount_cents: amount_cents}
  end

  defp allocation(:credit, room_pk, application_pk, amount_cents) do
    %RoomAllocation{
      room_id: room_pk,
      credit_application_id: application_pk,
      amount_cents: amount_cents
    }
  end

  defp paid_field(:cash), do: :cash_paid_cents
  defp paid_field(:credit), do: :credit_paid_cents

  defp fill_rooms(rooms, amount_cents), do: fill_rooms(rooms, amount_cents, [])

  defp fill_rooms(_rooms, 0, acc), do: Enum.reverse(acc)

  defp fill_rooms([], remaining, _acc) when remaining > 0 do
    raise "funding exceeds outstanding room deposit capacity"
  end

  defp fill_rooms([room | rooms], remaining, acc) do
    capacity = room.deposit_cents - room.cash_paid_cents - room.credit_paid_cents
    take = min(capacity, remaining)
    acc = if take > 0, do: [{room, take} | acc], else: acc
    fill_rooms(rooms, remaining - take, acc)
  end

  ## reschedule_group

  defp reschedule_group(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, new_arrival_on} <- fetch_date(op, "new_arrival_on"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on) do
      apply_reschedule(op_id, group, new_arrival_on)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp apply_reschedule(op_id, group, new_arrival_on) do
    # The departure shifts by the same number of days, so the length and
    # price of the stay are unchanged.
    stay_length = Date.diff(group.departure_on, group.arrival_on)
    new_departure_on = Date.add(new_arrival_on, stay_length)

    group =
      bump_group!(group,
        arrival_on: new_arrival_on,
        departure_on: new_departure_on
      )

    applied(op_id, %{
      "group_id" => group.group_id,
      "new_arrival_on" => Date.to_iso8601(new_arrival_on),
      "new_departure_on" => Date.to_iso8601(new_departure_on),
      "policy_version" => Groups.policy_version(group),
      "refundable_until" => Date.to_iso8601(Groups.refundable_until(group)),
      "revision" => group.revision
    })
  end

  ## cancel_group

  defp cancel_group(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, refund_method} <- fetch_refund_method(op),
         {:ok, group} <- fetch_group_with_rooms(group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_refund_method_available(group, occurred_on, refund_method) do
      apply_cancellation(op_id, group, occurred_on, refund_method)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  # Omitting the refund method preserves the existing cash behavior.
  defp fetch_refund_method(op) do
    case Map.get(op, "refund_method") do
      nil -> {:ok, "cash"}
      "cash" -> {:ok, "cash"}
      "hotel_credit" -> {:ok, "hotel_credit"}
      _other -> {:error, "invalid_operation"}
    end
  end

  # Hotel credit is not a way around a non-refundable policy.
  defp validate_refund_method_available(group, occurred_on, "hotel_credit") do
    if Groups.refundable?(group, occurred_on) do
      :ok
    else
      {:error, "refund_method_not_available"}
    end
  end

  defp validate_refund_method_available(_group, _occurred_on, "cash"), do: :ok

  # Full cancellation settles only the remaining active rooms; the group's
  # totals then describe no active rooms and drop to zero.
  defp apply_cancellation(op_id, group, occurred_on, refund_method) do
    rooms = Enum.filter(group.rooms, &(&1.status == "active"))

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      settle_rooms(group, rooms, occurred_on, refund_method, op_id)

    group =
      bump_group!(group,
        status: "cancelled",
        refunded_cents: group.refunded_cents + refunded_cents,
        retained_cents: group.retained_cents + retained_cents,
        converted_cents: group.converted_cents + converted_cents,
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        credit_paid_cents: 0
      )

    applied(op_id, %{
      "group_id" => group.group_id,
      "refunded_cents" => refunded_cents,
      "retained_cents" => retained_cents,
      "credit_issued_cents" => credit_issued_cents,
      "revision" => group.revision
    })
  end

  ## cancel_rooms

  defp cancel_rooms(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, refund_method} <- fetch_refund_method(op),
         {:ok, room_ids} <- fetch_room_ids(op),
         {:ok, group} <- fetch_group_with_rooms(group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         {:ok, rooms} <- resolve_active_rooms(group, room_ids),
         :ok <- validate_refund_method_available(group, occurred_on, refund_method) do
      apply_room_cancellation(op_id, group, rooms, occurred_on, refund_method)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  defp fetch_room_ids(op) do
    case Map.get(op, "room_ids") do
      room_ids when is_list(room_ids) -> {:ok, room_ids}
      _other -> {:error, "invalid_operation"}
    end
  end

  # Every supplied identifier must identify a distinct, active room of the
  # group. The selected rooms are reported in the group's original room
  # order regardless of the order supplied by the caller.
  defp resolve_active_rooms(group, room_ids) do
    cond do
      room_ids == [] ->
        {:error, "invalid_rooms"}

      length(Enum.uniq(room_ids)) != length(room_ids) ->
        {:error, "invalid_rooms"}

      true ->
        selected =
          Enum.filter(
            group.rooms,
            fn room -> room.status == "active" and room.room_id in room_ids end
          )

        if length(selected) == length(room_ids) do
          {:ok, selected}
        else
          {:error, "invalid_rooms"}
        end
    end
  end

  defp apply_room_cancellation(op_id, group, rooms, occurred_on, refund_method) do
    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      settle_rooms(group, rooms, occurred_on, refund_method, op_id)

    settled_pks = MapSet.new(Enum.map(rooms, & &1.id))

    remaining =
      Enum.filter(
        group.rooms,
        fn room -> room.status == "active" and not MapSet.member?(settled_pks, room.id) end
      )

    totals = totals_for(remaining)

    group =
      bump_group!(group,
        status: if(remaining == [], do: "cancelled", else: "active"),
        refunded_cents: group.refunded_cents + refunded_cents,
        retained_cents: group.retained_cents + retained_cents,
        converted_cents: group.converted_cents + converted_cents,
        lodging_total_cents: totals.lodging,
        deposit_due_cents: totals.due,
        deposit_paid_cents: totals.paid,
        credit_paid_cents: totals.credit
      )

    applied(op_id, %{
      "group_id" => group.group_id,
      "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
      "refunded_cents" => refunded_cents,
      "retained_cents" => retained_cents,
      "credit_issued_cents" => credit_issued_cents,
      "revision" => group.revision
    })
  end

  # Group totals are sums of the active rooms.
  defp totals_for(rooms) do
    %{
      lodging: rooms |> Enum.map(& &1.lodging_cents) |> Enum.sum(),
      due: rooms |> Enum.map(& &1.deposit_cents) |> Enum.sum(),
      paid: rooms |> Enum.map(&(&1.cash_paid_cents + &1.credit_paid_cents)) |> Enum.sum(),
      credit: rooms |> Enum.map(& &1.credit_paid_cents) |> Enum.sum()
    }
  end

  ## Shared settlement

  # Settles the selected rooms' allocated cash and credit. On a refundable
  # cancellation cash is refunded, or converted to one credit lot worth 110%
  # of the combined cash when hotel credit is selected (the bonus is
  # computed once on the combined amount, not separately per room); applied
  # credit returns to its original lots. A non-refundable cancellation
  # retains the cash and consumes the credit. Unpaid deposit for the
  # settled rooms ceases to be due; other rooms and their allocations are
  # unchanged.
  defp settle_rooms(group, rooms, occurred_on, refund_method, op_id) do
    refundable = Groups.refundable?(group, occurred_on)
    room_pks = Enum.map(rooms, & &1.id)

    allocations = Repo.all(from ra in RoomAllocation, where: ra.room_id in ^room_pks)

    cash_totals = sum_allocations(allocations, :cash_payment_id)
    credit_totals = sum_allocations(allocations, :credit_application_id)

    disposition_field =
      case {refundable, refund_method} do
        {true, "cash"} -> :refunded_cents
        {true, "hotel_credit"} -> :converted_cents
        {false, _other} -> :retained_cents
      end

    Enum.each(cash_totals, fn {payment_pk, amount_cents} ->
      Repo.update_all(
        from(p in CashPayment, where: p.id == ^payment_pk),
        inc: [{disposition_field, amount_cents}]
      )
    end)

    total_cash = cash_totals |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      case {refundable, refund_method} do
        {true, "cash"} ->
          {total_cash, 0, 0, 0}

        {true, "hotel_credit"} ->
          credit_issued_cents =
            convert_to_credit(group, op_id, total_cash, occurred_on, cash_totals)

          {0, 0, total_cash, credit_issued_cents}

        {false, _other} ->
          {0, total_cash, 0, 0}
      end

    Enum.each(credit_totals, fn {application_pk, amount_cents} ->
      application = Repo.get!(CreditApplication, application_pk)

      if refundable do
        restore_credit(application.lot_id, amount_cents, occurred_on)
      end

      settle_application(application, amount_cents)
    end)

    Repo.delete_all(from ra in RoomAllocation, where: ra.room_id in ^room_pks)

    Repo.update_all(
      from(r in Room, where: r.id in ^room_pks),
      set: [status: "cancelled"]
    )

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents}
  end

  defp sum_allocations(allocations, source_field) do
    allocations
    |> Enum.flat_map(fn allocation ->
      case Map.fetch(allocation, source_field) do
        {:ok, source_pk} when not is_nil(source_pk) -> [{source_pk, allocation.amount_cents}]
        _other -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {source_pk, amounts} -> {source_pk, Enum.sum(amounts)} end)
  end

  # The converted cash becomes one credit lot; each contributing payment's
  # converted amount is retained in funding order so a later chargeback can
  # compute its entitlement in the lot.
  defp convert_to_credit(_group, _op_id, 0, _occurred_on, _cash_totals), do: 0

  defp convert_to_credit(group, op_id, total_cash, occurred_on, cash_totals) do
    lot = issue_credit_lot(group.guest_id, op_id, total_cash, occurred_on)
    record_contributions(lot.id, cash_totals)
    lot.original_cents
  end

  # The lot is worth the cash plus a 10% bonus (the standard rounding rule
  # applies to the bonus), is available through 365 days after the
  # cancellation, and expires the following day.
  defp issue_credit_lot(guest_id, op_id, cash_cents, occurred_on) do
    bonus_cents = round_half_up(cash_cents * @credit_bonus_percent, 100)
    amount_cents = cash_cents + bonus_cents

    Repo.insert!(%CreditLot{
      guest_id: guest_id,
      source_operation_id: op_id,
      original_cents: amount_cents,
      remaining_cents: amount_cents,
      expires_on: Date.add(occurred_on, @credit_validity_days)
    })
  end

  # Contributions are kept in the funding order used by room accounting:
  # the unattributed senior block first (no payment identity), then
  # recorded payments in durable-record commit order.
  defp record_contributions(lot_pk, cash_totals) do
    payments = Repo.all(from p in CashPayment, where: p.id in ^Map.keys(cash_totals))

    operation_ids =
      for payment <- payments, is_binary(payment.operation_id), do: payment.operation_id

    record_ids =
      Repo.all(
        from r in OperationRecord,
          where: r.operation_id in ^operation_ids,
          select: {r.operation_id, r.id}
      )
      |> Map.new()

    {legacy_payments, recorded_payments} =
      Enum.split_with(payments, fn payment ->
        is_nil(payment.operation_id) or not Map.has_key?(record_ids, payment.operation_id)
      end)

    recorded_payments =
      Enum.sort_by(recorded_payments, fn payment ->
        Map.fetch!(record_ids, payment.operation_id)
      end)

    entries =
      legacy_entry(legacy_payments, cash_totals) ++
        Enum.map(recorded_payments, fn payment ->
          {payment.id, Map.fetch!(cash_totals, payment.id)}
        end)

    entries
    |> Enum.with_index()
    |> Enum.each(fn {{payment_pk, amount_cents}, position} ->
      Repo.insert!(%CreditLotContribution{
        lot_id: lot_pk,
        cash_payment_id: payment_pk,
        amount_cents: amount_cents,
        position: position
      })
    end)
  end

  defp legacy_entry([], _cash_totals), do: []

  defp legacy_entry(payments, cash_totals) do
    total =
      payments
      |> Enum.map(fn payment -> Map.fetch!(cash_totals, payment.id) end)
      |> Enum.sum()

    [{nil, total}]
  end

  # Restored credit extinguishes unrecovered clawback before any amount
  # becomes available; this absorption occurs before checking the lot's
  # expiry. Only an excess becomes available, or expires when the lot's
  # expiry is already past. The lot is re-read so successive restorations
  # to the same lot observe each other's absorption.
  defp restore_credit(lot_pk, amount_cents, occurred_on) do
    lot = Repo.get!(CreditLot, lot_pk)
    absorbed = min(amount_cents, lot.unrecovered_clawback_cents)

    if absorbed > 0 do
      Repo.update_all(
        from(l in CreditLot, where: l.id == ^lot.id),
        inc: [unrecovered_clawback_cents: -absorbed]
      )
    end

    remaining = amount_cents - absorbed

    if remaining > 0 and Date.compare(lot.expires_on, occurred_on) != :lt do
      Repo.update_all(
        from(l in CreditLot, where: l.id == ^lot.id),
        inc: [remaining_cents: remaining]
      )
    end
  end

  defp settle_application(application, amount_cents) do
    remaining = application.amount_cents - amount_cents

    if remaining == 0 do
      Repo.delete!(application)
    else
      application
      |> Changeset.change(amount_cents: remaining)
      |> Repo.update!()
    end
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, occurred_on} <- fetch_date(op, "occurred_on"),
         {:ok, amount_cents} <- fetch_present(op, "amount_cents"),
         {:ok, group} <- fetch_group_with_rooms(group_id),
         :ok <- check_expected_revision(op, group),
         :ok <- check_active(group),
         :ok <- validate_amount(amount_cents),
         :ok <- validate_outstanding(group, amount_cents),
         {:ok, lots} <- fetch_usable_lots(group.guest_id, occurred_on, amount_cents) do
      apply_credit(op_id, group, amount_cents, lots)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  # Credit application evaluates expiry using the operation's occurred_on
  # date. Lots are consumed by earliest expiry, then by source operation for
  # equal expiries.
  defp fetch_usable_lots(guest_id, occurred_on, amount_cents) do
    lots =
      Repo.all(
        from l in CreditLot,
          where:
            l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^occurred_on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )

    if lots |> Enum.map(& &1.remaining_cents) |> Enum.sum() >= amount_cents do
      {:ok, lots}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp apply_credit(op_id, group, amount_cents, lots) do
    Enum.reduce(allocate(lots, amount_cents), group.rooms, fn {lot, applied_cents}, rooms ->
      Repo.update_all(
        from(l in CreditLot, where: l.id == ^lot.id),
        inc: [remaining_cents: -applied_cents]
      )

      application =
        Repo.insert!(%CreditApplication{
          lot_id: lot.id,
          group_id: group.id,
          amount_cents: applied_cents,
          operation_id: stored_operation_id(op_id)
        })

      allocate_funding(rooms, :credit, application.id, applied_cents)
    end)

    group =
      bump_group!(group,
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        credit_paid_cents: group.credit_paid_cents + amount_cents
      )

    applied(op_id, %{
      "group_id" => group.group_id,
      "amount_cents" => amount_cents,
      "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
      "revision" => group.revision
    })
  end

  defp allocate(_lots, 0), do: []

  defp allocate([lot | lots], remaining_cents) do
    take = min(lot.remaining_cents, remaining_cents)
    [{lot, take} | allocate(lots, remaining_cents - take)]
  end

  ## reduce_cash_payment

  defp reduce_cash_payment(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, payment_operation_id} <- fetch_string(op, "payment_operation_id"),
         {:ok, payment, group} <- fetch_reducible_payment(payment_operation_id),
         :ok <- check_expected_revision(op, group),
         :ok <- validate_held_present(payment),
         {:ok, amount_cents} <- fetch_present(op, "amount_cents"),
         :ok <- validate_amount(amount_cents),
         :ok <- validate_reduction(payment, amount_cents) do
      apply_reduction(op_id, payment_operation_id, payment, group, amount_cents)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  # The addressed group is the original payment's group. A target can be
  # reduced only when it is a durably recorded, applied cash payment.
  defp fetch_reducible_payment(payment_operation_id) do
    case fetch_applied_payment(payment_operation_id) do
      {:ok, payment, group} -> {:ok, payment, group}
      {:error, "operation_not_found"} -> {:error, "operation_not_found"}
      {:error, _other} -> {:error, "payment_not_reducible"}
    end
  end

  defp validate_held_present(payment) do
    if held_cents(payment) > 0 do
      :ok
    else
      {:error, "payment_not_reducible"}
    end
  end

  defp validate_reduction(payment, amount_cents) do
    if amount_cents <= held_cents(payment) do
      :ok
    else
      {:error, "reduction_exceeds_held_cash"}
    end
  end

  # A reduction removes held allocations belonging to the target payment in
  # reverse fill order; the group's outstanding deposit reopens by the
  # amount removed. Successive reductions compose against the payment's
  # remaining held cash.
  defp apply_reduction(op_id, payment_operation_id, payment, group, amount_cents) do
    remove_held_cash(payment.id, amount_cents)

    Repo.update_all(
      from(p in CashPayment, where: p.id == ^payment.id),
      inc: [reduced_cents: amount_cents]
    )

    group =
      bump_group!(group,
        deposit_paid_cents: group.deposit_paid_cents - amount_cents,
        cash_reduced_cents: group.cash_reduced_cents + amount_cents
      )

    applied(op_id, %{
      "payment_operation_id" => payment_operation_id,
      "group_id" => group.group_id,
      "amount_cents" => amount_cents,
      "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
      "revision" => group.revision
    })
  end

  ## charge_back_payment

  defp charge_back_payment(op) do
    with {:ok, op_id} <- fetch_string(op, "operation_id"),
         {:ok, payment_operation_id} <- fetch_string(op, "payment_operation_id"),
         {:ok, payment, group} <- fetch_chargeable_payment(payment_operation_id),
         :ok <- check_expected_revision(op, group),
         :ok <- validate_chargeable(payment) do
      apply_chargeback(op_id, payment_operation_id, payment, group)
    else
      {:error, code} ->
        rejected(Map.get(op, "operation_id"), code)

      {:stale, expected, actual, group} ->
        stale_rejected(Map.get(op, "operation_id"), group, expected, actual)
    end
  end

  defp fetch_chargeable_payment(payment_operation_id) do
    case fetch_applied_payment(payment_operation_id) do
      {:ok, payment, group} -> {:ok, payment, group}
      {:error, "operation_not_found"} -> {:error, "operation_not_found"}
      {:error, _other} -> {:error, "payment_not_chargeable"}
    end
  end

  # A payment can be charged back whether its group is active or cancelled,
  # but not when it was already charged back or fully reduced.
  defp validate_chargeable(payment) do
    if payment.charged_back_cents > 0 or payment.reduced_cents == payment.amount_cents do
      {:error, "payment_not_chargeable"}
    else
      :ok
    end
  end

  # Reverses all cash from the payment except any portion already recorded
  # as reduced: held allocations are removed in reverse fill order,
  # refunded and retained portions move to charged-back cash without
  # reversing the historical refund or retention, and converted principal
  # moves to charged-back cash while the credit entitlement it created is
  # revoked. Only the original payment's group changes.
  defp apply_chargeback(op_id, payment_operation_id, payment, group) do
    held = held_cents(payment)
    if held > 0, do: remove_held_cash(payment.id, held)
    if payment.converted_cents > 0, do: claw_back_credit(payment)

    charged_back_cents =
      held + payment.refunded_cents + payment.retained_cents + payment.converted_cents

    Repo.update_all(
      from(p in CashPayment, where: p.id == ^payment.id),
      set: [
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0,
        charged_back_cents: charged_back_cents
      ]
    )

    group =
      bump_group!(group,
        deposit_paid_cents: group.deposit_paid_cents - held,
        refunded_cents: group.refunded_cents - payment.refunded_cents,
        retained_cents: group.retained_cents - payment.retained_cents,
        converted_cents: group.converted_cents - payment.converted_cents,
        cash_charged_back_cents: group.cash_charged_back_cents + charged_back_cents
      )

    applied(op_id, %{
      "payment_operation_id" => payment_operation_id,
      "group_id" => group.group_id,
      "charged_back_cents" => charged_back_cents,
      "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group),
      "revision" => group.revision
    })
  end

  # Clawbacks remove each payment's entitlement from the lot's remaining
  # balance first; any entitlement that cannot be removed becomes the lot's
  # unrecovered clawback. Credit within a lot remains fungible; spending is
  # never attributed back to individual payments.
  defp claw_back_credit(payment) do
    payment.id
    |> contributed_lot_ids()
    |> Enum.each(fn lot_pk ->
      contributions =
        Repo.all(
          from c in CreditLotContribution,
            where: c.lot_id == ^lot_pk,
            order_by: [asc: c.position]
        )

      entitlement = entitlement_for_payment(payment.id, contributions)
      lot = Repo.get!(CreditLot, lot_pk)
      removed = min(entitlement, lot.remaining_cents)

      Repo.update_all(
        from(l in CreditLot, where: l.id == ^lot_pk),
        inc: [
          remaining_cents: -removed,
          unrecovered_clawback_cents: entitlement - removed
        ]
      )
    end)
  end

  defp contributed_lot_ids(payment_pk) do
    Repo.all(
      from c in CreditLotContribution,
        where: c.cash_payment_id == ^payment_pk,
        group_by: c.lot_id,
        select: c.lot_id
    )
  end

  # A payment's entitlement in one lot is the 10%-bonus value of the
  # settled cash through its contribution minus the bonus value through the
  # preceding contribution, with the standard half-up rounding applied to
  # both running totals. The entitlements telescope exactly to the issued
  # lot and are calculated independently for each lot.
  defp entitlement_for_payment(payment_pk, contributions) do
    {entitlement, _cumulative} =
      Enum.reduce(contributions, {0, 0}, fn contribution, {entitlement, cumulative} ->
        next_cumulative = cumulative + contribution.amount_cents

        entitlement =
          if contribution.cash_payment_id == payment_pk do
            entitlement + lot_value_cents(next_cumulative) - lot_value_cents(cumulative)
          else
            entitlement
          end

        {entitlement, next_cumulative}
      end)

    entitlement
  end

  defp lot_value_cents(cash_cents) do
    cash_cents + round_half_up(cash_cents * @credit_bonus_percent, 100)
  end

  ## Payment lookup and dispositions

  defp fetch_applied_payment(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, "operation_not_found"}

      %OperationRecord{type: "record_cash_payment", result: %{"status" => "applied"}} ->
        case Repo.get_by(CashPayment, operation_id: payment_operation_id) do
          nil -> {:error, "payment_not_found"}
          payment -> {:ok, payment, Repo.get!(Group, payment.group_id)}
        end

      _other ->
        {:error, "not_an_applied_payment"}
    end
  end

  # Cash still held on rooms; refunded, retained, converted, reduced, and
  # charged-back cash is settled history and never moves again.
  defp held_cents(payment) do
    payment.amount_cents - payment.refunded_cents - payment.retained_cents -
      payment.converted_cents - payment.reduced_cents - payment.charged_back_cents
  end

  # Held allocations are removed in reverse fill order: the last room the
  # payment funded is the first room released, reopening that room's
  # outstanding deposit.
  defp remove_held_cash(payment_pk, amount_cents) do
    payment_pk
    |> held_allocations()
    |> remove_allocations(amount_cents)
  end

  defp held_allocations(payment_pk) do
    Repo.all(
      from ra in RoomAllocation,
        join: r in Room,
        on: ra.room_id == r.id,
        where: ra.cash_payment_id == ^payment_pk,
        order_by: [desc: r.position]
    )
  end

  defp remove_allocations(_rows, 0), do: :ok

  defp remove_allocations([], remaining) when remaining > 0 do
    raise "held allocations do not cover the removed cash amount"
  end

  defp remove_allocations([row | rows], remaining) do
    take = min(row.amount_cents, remaining)

    if take == row.amount_cents do
      Repo.delete!(row)
    else
      Repo.update_all(
        from(ra in RoomAllocation, where: ra.id == ^row.id),
        inc: [amount_cents: -take]
      )
    end

    Repo.update_all(
      from(r in Room, where: r.id == ^row.room_id),
      inc: [cash_paid_cents: -take]
    )

    remove_allocations(rows, remaining - take)
  end

  ## Shared helpers

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp fetch_group_with_rooms(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:error, "group_not_found"}

      group ->
        {:ok, Repo.preload(group, rooms: from(r in Room, order_by: [asc: r.position]))}
    end
  end

  # Group existence is resolved before comparing revisions; a stale revision
  # is rejected before the operation's other domain rules.
  defp check_expected_revision(op, group) do
    case Map.get(op, "expected_revision") do
      nil ->
        :ok

      expected ->
        if expected == group.revision do
          :ok
        else
          {:stale, expected, group.revision, group}
        end
    end
  end

  defp check_active(%Group{status: "active"}), do: :ok
  defp check_active(%Group{}), do: {:error, "group_not_active"}

  defp fetch_string(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "invalid_operation"}
    end
  end

  defp fetch_date(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, "invalid_operation"}
        end

      _other ->
        {:error, "invalid_operation"}
    end
  end

  defp fetch_present(op, key) do
    case Map.fetch(op, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp fetch_rooms(op) do
    case Map.get(op, "rooms") do
      rooms when is_list(rooms) -> {:ok, rooms}
      _other -> {:error, "invalid_operation"}
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp stored_operation_id(op_id) when is_binary(op_id), do: op_id
  defp stored_operation_id(_op_id), do: nil

  # Applies the given field changes and increments the group's revision
  # exactly once. The revision guard keeps concurrent updates from
  # clobbering each other.
  defp bump_group!(%Group{} = group, fields) do
    now = NaiveDateTime.utc_now(:second)

    {updated, _} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision),
        set: fields ++ [revision: group.revision + 1, updated_at: now]
      )

    if updated != 1 do
      Repo.rollback(:stale_group)
    end

    Repo.get!(Group, group.id)
  end

  defp applied(op_id, fields) do
    Map.merge(%{"operation_id" => op_id, "status" => "applied"}, fields)
  end

  defp rejected(op_id, code) do
    %{"operation_id" => op_id, "status" => "rejected", "code" => code}
  end

  defp stale_rejected(op_id, group, expected_revision, actual_revision) do
    %{
      "operation_id" => op_id,
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group.group_id,
      "expected_revision" => expected_revision,
      "actual_revision" => actual_revision
    }
  end
end
