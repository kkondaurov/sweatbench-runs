defmodule GroupStay.Groups do
  @moduledoc """
  The Groups context owns group reservations: opening them, recording cash and
  hotel credit against their deposits, rescheduling their stays, and
  cancelling all or part of them, as well as the credit lots and finance
  totals derived from those records.

  Cash and credit fund active room deposits in the rooms' original order,
  filling one room's deposit before moving to the next. Every recorded cash
  payment is tracked as a cash funding whose disposition (held, refunded,
  retained, converted, reduced, or charged back) is always fully accounted
  for, so one payment can be reconciled exactly against the group, room, and
  ledger views.

  Partner operations are applied one at a time, each in its own transaction.
  The first operation received for an `operation_id` is remembered durably,
  together with its result; a later submission with the same identifier and an
  equivalent payload is answered from that record without reading or changing
  domain state, so a rejected operation leaves the database exactly as it was
  and never stops later operations in the same batch.
  """

  import Ecto.Query

  alias Ecto.Changeset

  alias GroupStay.Groups.{
    CashFunding,
    CreditApplication,
    CreditLot,
    CreditLotEntitlement,
    Group,
    OperationRecord,
    Room,
    RoomFunding
  }

  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @refund_methods ~w(cash hotel_credit)

  # Flexible groups booked before this date keep the original 14-day
  # cancellation window; flexible groups booked on or after it use 30 days.
  @flex_policy_cutover ~D[2027-01-01]

  # A credit lot issued on cancellation is available through the date 365
  # days after cancellation and expires the following day.
  @credit_lifetime_days 365

  ## Reads

  @doc """
  Fetches a group by its partner-supplied `group_id`, with rooms in their
  original order and totals describing the active rooms. Returns `:error`
  when no such group exists.
  """
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :error
      %Group{} = group -> {:ok, present_group(group)}
    end
  end

  def get_group(_group_id), do: :error

  # Rooms in their original order with their held funding summed into the
  # virtual paid fields, plus the group totals over the active rooms.
  defp present_group(group) do
    rooms = load_rooms(group.id)

    group
    |> Map.merge(active_totals(rooms))
    |> Map.put(:rooms, rooms)
  end

  defp load_rooms(group_id) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group_id,
        order_by: [asc: r.position],
        preload: [:room_fundings]
    )
    |> Enum.map(&present_room/1)
  end

  defp present_room(%Room{status: "active"} = room) do
    %{
      room
      | cash_paid_cents: held_sum(room, "cash"),
        credit_paid_cents: held_sum(room, "credit")
    }
  end

  defp present_room(%Room{} = room), do: %{room | cash_paid_cents: 0, credit_paid_cents: 0}

  defp held_sum(room, kind) do
    Enum.sum(
      for allocation <- room.room_fundings,
          allocation.kind == kind and allocation.status == "held",
          do: allocation.amount_cents
    )
  end

  # The group's lodging, due, paid, and outstanding totals describe active
  # rooms only.
  defp active_totals(rooms) do
    active_rooms = Enum.filter(rooms, &(&1.status == "active"))

    cash_paid_cents = Enum.sum(for room <- active_rooms, do: room.cash_paid_cents)
    credit_paid_cents = Enum.sum(for room <- active_rooms, do: room.credit_paid_cents)

    %{
      lodging_total_cents: Enum.sum(for room <- active_rooms, do: room.lodging_total_cents),
      deposit_due_cents: Enum.sum(for room <- active_rooms, do: room.deposit_due_cents),
      deposit_paid_cents: cash_paid_cents + credit_paid_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents
    }
  end

  defp refresh_group_totals(group), do: active_totals(load_rooms(group.id))

  defp active_rooms(group_id) do
    group_id |> load_rooms() |> Enum.filter(&(&1.status == "active"))
  end

  @doc """
  The last date on which cancelling the group is refundable: the arrival date
  minus the group's fixed cancellation window. `nil` for advance-purchase
  groups, which are never refundable.
  """
  def refundable_until(%Group{} = group) do
    case cancellation_window(group.policy_version) do
      nil -> nil
      window_days -> Date.add(group.arrival_on, -window_days)
    end
  end

  defp cancellation_window("flex-14"), do: 14
  defp cancellation_window("flex-30"), do: 30
  defp cancellation_window(_policy_version), do: nil

  @doc """
  Finance totals across all groups and credit lots, reporting credit expiry
  as of `on_date`: cash held against active reservations, cash refunded,
  retained, converted to credit, reduced, or charged back, the outstanding
  credit liability, and the current credit shortfall from clawbacks. Unpaid
  deposit requirements never appear in these totals.
  """
  def ledger_totals(on_date \\ Date.utc_today()) do
    %{
      cash_held_cents: held_cash(),
      cash_refunded_cents: funding_sum(:refunded_cents),
      cash_retained_cents: funding_sum(:retained_cents),
      cash_converted_to_credit_cents: funding_sum(:converted_cents),
      cash_reduced_cents: funding_sum(:reduced_cents),
      cash_charged_back_cents: funding_sum(:charged_back_cents),
      credit_liability_cents: credit_liability(on_date),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  # Cash currently applied to active reservations.
  defp held_cash do
    Repo.one(
      from f in CashFunding,
        join: g in Group,
        on: f.group_id == g.id,
        where: g.status == "active",
        select: coalesce(sum(f.held_cents), 0)
    )
  end

  defp funding_sum(field) do
    Repo.one(from f in CashFunding, select: coalesce(sum(field(f, ^field)), 0))
  end

  # The credit liability covers both available credit and credit currently
  # applied to active groups, including credit covered by a current
  # shortfall. Expiry, non-refundable consumption, entitlement revocation,
  # and shortfall absorption reduce it; applying or restoring credit merely
  # moves it between the two parts.
  defp credit_liability(on_date) do
    available_cents =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on_date,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    available_cents + applied_credit_cents()
  end

  defp applied_credit_cents do
    Repo.one(
      from rf in RoomFunding,
        join: r in Room,
        on: rf.room_id == r.id,
        join: g in Group,
        on: r.group_id == g.id,
        where: rf.kind == "credit" and rf.status == "held" and g.status == "active",
        select: coalesce(sum(rf.amount_cents), 0)
    )
  end

  # A lot's current shortfall is the lesser of its unrecovered clawback and
  # the credit from that lot still applied to active groups.
  defp credit_shortfall do
    applied_by_lot =
      Repo.all(
        from rf in RoomFunding,
          join: a in CreditApplication,
          on: rf.credit_application_id == a.id,
          join: r in Room,
          on: rf.room_id == r.id,
          join: g in Group,
          on: r.group_id == g.id,
          where: rf.kind == "credit" and rf.status == "held" and g.status == "active",
          group_by: a.credit_lot_id,
          select: {a.credit_lot_id, coalesce(sum(rf.amount_cents), 0)}
      )
      |> Map.new()

    lots = Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)

    Enum.sum(
      for lot <- lots,
          do: min(lot.unrecovered_clawback_cents, Map.get(applied_by_lot, lot.id, 0))
    )
  end

  @doc """
  A guest's hotel credit as of `on_date`: the available total and the
  unexpired, unexhausted lots ordered by expiry and then source operation.
  """
  def guest_credit(guest_id, on_date \\ Date.utc_today()) do
    lots = available_lots(guest_id, on_date)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(for lot <- lots, do: lot.remaining_cents),
      lots: Enum.map(lots, &lot_data/1)
    }
  end

  defp lot_data(%CreditLot{} = lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_string(lot.expires_on)
    }
  end

  # Lots available to a guest as of `on_date`, in consumption order: earliest
  # expiry first, then `source_operation_id` for equal expiries.
  defp available_lots(guest_id, on_date) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on_date,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
  end

  @doc """
  Fetches the remembered result for an `operation_id`. Returns `:error` when
  no operation under that identifier has been received.
  """
  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> :error
      %OperationRecord{} = record -> {:ok, record.result}
    end
  end

  def get_operation_result(_operation_id), do: :error

  @doc """
  Reconciles one durably recorded, applied cash payment: the current
  disposition of every recorded cent. Returns `:error` when no operation
  under that identifier has been received, and `:not_reconcilable` when the
  record exists but is not an applied cash payment.
  """
  def get_payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        :error

      %OperationRecord{} = record ->
        if applied_cash_payment?(record) do
          case Repo.get_by(CashFunding, operation_id: record.operation_id) do
            %CashFunding{} = funding -> {:ok, payment_statement(record, funding)}
            nil -> :not_reconcilable
          end
        else
          :not_reconcilable
        end
    end
  end

  def get_payment_statement(_payment_operation_id), do: :error

  defp payment_statement(record, funding) do
    %{
      payment_operation_id: record.operation_id,
      original_group_id: record.result["group_id"],
      recorded_cents: funding.amount_cents,
      held_cents: funding.held_cents,
      refunded_cents: funding.refunded_cents,
      retained_cents: funding.retained_cents,
      converted_to_credit_cents: funding.converted_cents,
      reduced_cents: funding.reduced_cents,
      charged_back_cents: funding.charged_back_cents
    }
  end

  defp applied_cash_payment?(%OperationRecord{} = record) do
    record.type == "record_cash_payment" and is_map(record.result) and
      record.result["status"] == "applied"
  end

  ## Partner operations

  @doc """
  Applies partner operations in array order and returns one result map per
  operation, in the same order. An operation can observe changes made by
  earlier operations in the same batch; a rejected operation changes nothing.

  The first operation received for an `operation_id` commits its idempotency
  record in the same transaction as its domain changes (handled rejections
  commit only the record). A retry with an equivalent payload is answered from
  the stored record; the same identifier with a different payload is rejected
  with `operation_id_conflict`.
  """
  def apply_operations(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  defp apply_operation(operation) do
    {:ok, result} = Repo.transact(fn -> process_operation(operation) end)
    result
  rescue
    e in Ecto.ConstraintError ->
      # A concurrent first attempt with the same operation_id won the race and
      # committed its record between our lookup and our insert. Its record
      # decides the outcome; anything else is an unexpected fault and aborts
      # the request so the gateway can retry the batch.
      case raced_record(operation) do
        %OperationRecord{} = record -> remembered_outcome(record, operation)
        nil -> reraise e, __STACKTRACE__
      end
  end

  defp process_operation(operation) do
    case fetch_operation_id(operation) do
      {:ok, operation_id} ->
        case Repo.get_by(OperationRecord, operation_id: operation_id) do
          %OperationRecord{} = record -> {:ok, remembered_outcome(record, operation)}
          nil -> {:ok, process_and_remember(operation, operation_id)}
        end

      :error ->
        # Without a partner-supplied identifier there is nothing to key an
        # idempotency record on; process the operation as received.
        {:ok, operation_outcome(operation)}
    end
  end

  # The record already holds the outcome for this identifier: an equivalent
  # payload is answered with the exact original result, anything else is a
  # conflict that must not replace the original record.
  defp remembered_outcome(%OperationRecord{} = record, operation) do
    if equivalent_submission?(record.submission, operation) do
      record.result
    else
      conflict_result(operation)
    end
  end

  defp process_and_remember(operation, operation_id) do
    result = operation_outcome(operation)
    remember!(operation_id, operation, result)
    result
  end

  defp operation_outcome(operation) do
    case do_apply(operation) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp remember!(operation_id, operation, result) do
    %OperationRecord{}
    |> OperationRecord.changeset(%{
      operation_id: operation_id,
      type: operation_type(operation),
      submission: operation,
      result: result
    })
    |> Repo.insert!()
  end

  defp operation_type(operation) when is_map(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp operation_type(_operation), do: nil

  defp fetch_operation_id(operation) when is_map(operation) do
    case Map.get(operation, "operation_id") do
      operation_id when is_binary(operation_id) -> {:ok, operation_id}
      _other -> :error
    end
  end

  defp fetch_operation_id(_operation), do: :error

  defp raced_record(operation) do
    case fetch_operation_id(operation) do
      {:ok, operation_id} -> Repo.get_by(OperationRecord, operation_id: operation_id)
      :error -> nil
    end
  end

  # Payloads are equivalent when their JSON values match, ignoring object key
  # order. Array order and values remain significant, and an integer is not
  # the same value as a float.
  defp equivalent_submission?(stored_submission, operation) do
    canonical(stored_submission) === canonical(operation)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, value} -> {key, canonical(value)} end)
    |> Enum.sort()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp conflict_result(operation) do
    {:error, result} = rejected(operation, "operation_id_conflict")
    result
  end

  defp do_apply(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp do_apply(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp do_apply(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp do_apply(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)

  defp do_apply(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp do_apply(%{"type" => "cancel_rooms"} = operation), do: cancel_rooms(operation)

  defp do_apply(%{"type" => "reduce_cash_payment"} = operation),
    do: reduce_cash_payment(operation)

  defp do_apply(%{"type" => "charge_back_payment"} = operation),
    do: charge_back_payment(operation)

  defp do_apply(operation) when is_map(operation), do: rejected(operation, "invalid_operation")

  defp do_apply(_operation), do: rejected(%{}, "invalid_operation")

  ## open_group

  defp open_group(operation) do
    with :ok <- require_fields(operation, ["group_id", "guest_id", "property_id"]),
         {:ok, booked_on} <- fetch_occurred_on(operation),
         :ok <- ensure_group_absent(Map.get(operation, "group_id")),
         {:ok, arrival_on, departure_on} <- stay_dates(operation),
         {:ok, rooms} <- valid_rooms(Map.get(operation, "rooms")),
         :ok <- valid_rate_plan(Map.get(operation, "rate_plan")) do
      create_group(operation, booked_on, arrival_on, departure_on, rooms)
    else
      error -> rejection_for(operation, error)
    end
  end

  defp create_group(operation, booked_on, arrival_on, departure_on, rooms) do
    rate_plan = Map.get(operation, "rate_plan")
    nights = Date.diff(departure_on, arrival_on)

    room_attrs =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        lodging_total_cents = nights * Map.get(room, "nightly_rate_cents")

        %{
          room_id: Map.get(room, "room_id"),
          nightly_rate_cents: Map.get(room, "nightly_rate_cents"),
          position: position,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: room_deposit(rate_plan, lodging_total_cents)
        }
      end)

    lodging_total_cents = Enum.sum(for room <- room_attrs, do: room.lodging_total_cents)
    deposit_due_cents = Enum.sum(for room <- room_attrs, do: room.deposit_due_cents)

    attrs = %{
      group_id: Map.get(operation, "group_id"),
      guest_id: Map.get(operation, "guest_id"),
      property_id: Map.get(operation, "property_id"),
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: rate_plan,
      policy_version: policy_version(rate_plan, booked_on),
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      rooms: room_attrs
    }

    case %Group{} |> Group.changeset(attrs) |> Repo.insert() do
      {:ok, group} ->
        applied(operation, %{
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        })

      {:error, %Changeset{}} ->
        rejected(operation, "group_already_exists")
    end
  end

  # A group's policy version is fixed when the group is opened, from its rate
  # plan and booking date; rescheduling never moves it to a newer policy.
  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @flex_policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  # A flexible room requires 20% of its lodging amount as deposit. An
  # advance-purchase room requires its full lodging amount.
  defp room_deposit("flexible", lodging_cents), do: percent_of(lodging_cents, 20)
  defp room_deposit("advance_purchase", lodging_cents), do: lodging_cents

  # Percentages round to the nearest cent; an exact half-cent rounds upward.
  defp percent_of(cents, percent), do: div(cents * percent + 50, 100)

  ## record_cash_payment

  defp record_cash_payment(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- payment_amount(Map.get(operation, "amount_cents")),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      funding =
        %CashFunding{}
        |> CashFunding.changeset(%{
          group_id: group.id,
          operation_id: Map.get(operation, "operation_id"),
          amount_cents: amount_cents,
          held_cents: amount_cents
        })
        |> Repo.insert!()

      fill_rooms(group, {:cash, funding}, amount_cents)

      totals = refresh_group_totals(group)
      group = update_group!(group, totals)

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents,
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  defp payment_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp payment_amount(_amount_cents), do: {:error, "invalid_amount"}

  defp ensure_within_outstanding(group, amount_cents) do
    if amount_cents <= group.deposit_due_cents - group.deposit_paid_cents do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  # Fills the group's active rooms in their original order, filling one
  # room's remaining deposit before moving to the next.
  defp fill_rooms(group, source, amount_cents) do
    rooms = active_rooms(group.id)

    left =
      Enum.reduce(rooms, amount_cents, fn room, left ->
        remaining_cents = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        take_cents = min(remaining_cents, left)

        if take_cents > 0 do
          insert_room_funding!(room, source, take_cents)
        end

        left - take_cents
      end)

    if left != 0 do
      raise "funding exceeds the outstanding deposit of group #{group.group_id}"
    end

    :ok
  end

  defp insert_room_funding!(room, {:cash, %CashFunding{} = funding}, amount_cents) do
    %RoomFunding{}
    |> RoomFunding.changeset(%{
      room_id: room.id,
      kind: "cash",
      status: "held",
      amount_cents: amount_cents,
      cash_funding_id: funding.id
    })
    |> Repo.insert!()
  end

  defp insert_room_funding!(room, {:credit, %CreditApplication{} = application}, amount_cents) do
    %RoomFunding{}
    |> RoomFunding.changeset(%{
      room_id: room.id,
      kind: "credit",
      status: "held",
      amount_cents: amount_cents,
      credit_application_id: application.id
    })
    |> Repo.insert!()
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         {:ok, amount_cents} <- payment_amount(Map.get(operation, "amount_cents")),
         :ok <- ensure_within_outstanding(group, amount_cents),
         {:ok, takes} <- credit_coverage(group.guest_id, amount_cents, occurred_on) do
      Enum.each(takes, fn {lot, take_cents} ->
        lot
        |> Changeset.change(remaining_cents: lot.remaining_cents - take_cents)
        |> Repo.update!()

        application =
          %CreditApplication{}
          |> CreditApplication.changeset(%{
            credit_lot_id: lot.id,
            group_id: group.id,
            amount_cents: take_cents,
            status: "applied",
            operation_id: Map.get(operation, "operation_id")
          })
          |> Repo.insert!()

        fill_rooms(group, {:credit, application}, take_cents)
      end)

      totals = refresh_group_totals(group)
      group = update_group!(group, totals)

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents,
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  # Plans how the guest's unexpired lots cover the requested amount, consuming
  # lots by earliest expiry and then by source_operation_id. The operation's
  # occurred_on date decides which lots have expired.
  defp credit_coverage(guest_id, amount_cents, occurred_on) do
    lots = available_lots(guest_id, occurred_on)
    available_cents = Enum.sum(for lot <- lots, do: lot.remaining_cents)

    if available_cents < amount_cents do
      {:error, "insufficient_credit"}
    else
      {takes, _uncovered} =
        Enum.map_reduce(lots, amount_cents, fn lot, uncovered ->
          take_cents = min(lot.remaining_cents, uncovered)
          {{lot, take_cents}, uncovered - take_cents}
        end)

      takes = for {lot, take_cents} <- takes, take_cents > 0, do: {lot, take_cents}
      {:ok, takes}
    end
  end

  ## reschedule_group

  defp reschedule_group(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         {:ok, new_arrival_on} <- new_arrival(operation, occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)
      group = update_group!(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on})

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: Date.to_string(group.arrival_on),
        new_departure_on: Date.to_string(group.departure_on),
        policy_version: group.policy_version,
        refundable_until: format_date(refundable_until(group)),
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  defp new_arrival(operation, occurred_on) do
    case parse_date(Map.get(operation, "new_arrival_on")) do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          {:ok, new_arrival_on}
        else
          {:error, "invalid_stay"}
        end

      :error ->
        {:error, "invalid_stay"}
    end
  end

  ## cancel_group

  defp cancel_group(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         {:ok, refund_method} <- fetch_refund_method(operation),
         :ok <- ensure_refund_method_available(group, occurred_on, refund_method) do
      # A full cancellation settles only the remaining active rooms.
      rooms = active_rooms(group.id)
      settlement = settle_rooms(group, rooms, occurred_on, refund_method, operation)

      group = update_group!(group, settle_group_attrs(group, settlement, "cancelled"))

      applied(operation, %{
        group_id: group.group_id,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  ## cancel_rooms

  defp cancel_rooms(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         {:ok, refund_method} <- fetch_refund_method(operation),
         :ok <- ensure_refund_method_available(group, occurred_on, refund_method),
         {:ok, rooms} <- fetch_selected_rooms(operation, group) do
      settlement = settle_rooms(group, rooms, occurred_on, refund_method, operation)
      status = if active_rooms(group.id) == [], do: "cancelled", else: "active"

      group = update_group!(group, settle_group_attrs(group, settlement, status))

      applied(operation, %{
        group_id: group.group_id,
        cancelled_room_ids: Enum.map(rooms, & &1.room_id),
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  # All supplied room identifiers must identify distinct, active rooms in the
  # group. The selected rooms come back in the group's original room order.
  defp fetch_selected_rooms(operation, group) do
    case Map.get(operation, "room_ids") do
      room_ids when is_list(room_ids) and room_ids != [] ->
        active_by_room_id =
          group.id
          |> active_rooms()
          |> Map.new(fn room -> {room.room_id, room} end)

        distinct? = length(room_ids) == length(Enum.uniq(room_ids))

        if distinct? and Enum.all?(room_ids, &Map.has_key?(active_by_room_id, &1)) do
          rooms =
            room_ids
            |> Enum.map(&Map.fetch!(active_by_room_id, &1))
            |> Enum.sort_by(& &1.position)

          {:ok, rooms}
        else
          {:error, "invalid_rooms"}
        end

      _other ->
        {:error, "invalid_rooms"}
    end
  end

  # Omitting refund_method means cash, preserving existing callers.
  defp fetch_refund_method(operation) do
    case Map.get(operation, "refund_method") do
      nil -> {:ok, "cash"}
      refund_method when refund_method in @refund_methods -> {:ok, refund_method}
      _other -> {:error, "invalid_operation"}
    end
  end

  # Hotel credit is not a way around a non-refundable policy.
  defp ensure_refund_method_available(group, occurred_on, "hotel_credit") do
    if refundable?(group, occurred_on) do
      :ok
    else
      {:error, "refund_method_not_available"}
    end
  end

  defp ensure_refund_method_available(_group, _occurred_on, "cash"), do: :ok

  # A flexible group cancelled on or before its refundable_until date is
  # refundable; advance-purchase groups never are.
  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      last_refundable_date -> Date.compare(occurred_on, last_refundable_date) != :gt
    end
  end

  # Builds the settlement's update to the group's totals and cumulative
  # counters; the revision increment happens in update_group!.
  defp settle_group_attrs(group, settlement, status) do
    group
    |> refresh_group_totals()
    |> Map.merge(%{
      status: status,
      refunded_cents: group.refunded_cents + settlement.refunded_cents,
      retained_cents: group.retained_cents + settlement.retained_cents,
      cash_converted_cents: group.cash_converted_cents + settlement.converted_cents
    })
  end

  # Settles the selected active rooms (in booking order) under the group's
  # fixed policy: allocated cash is refunded, retained, or converted to a new
  # credit lot; allocated credit is restored to its original lots or
  # consumed; unpaid deposit for those rooms ceases to be due. Other rooms
  # and their allocations are unchanged.
  defp settle_rooms(group, rooms, occurred_on, refund_method, operation) do
    refundable = refundable?(group, occurred_on)
    room_ids = Enum.map(rooms, & &1.id)

    classification =
      cond do
        not refundable -> :retained_cents
        refund_method == "cash" -> :refunded_cents
        true -> :converted_cents
      end

    cash_rows = held_cash_rows(room_ids)
    moved_by_funding = moved_by_funding(cash_rows)
    settled_cents = Enum.sum(for {_funding, cents} <- moved_by_funding, do: cents)

    settle_cash_rows!(cash_rows, moved_by_funding, classification)

    credit_issued_cents =
      if classification == :converted_cents do
        issue_credit_lot(group, occurred_on, Map.get(operation, "operation_id"), moved_by_funding)
      else
        0
      end

    settle_credit_rows!(room_ids, refundable)
    settle_rooms!(rooms, cash_rows, classification)

    %{
      refunded_cents: if(classification == :refunded_cents, do: settled_cents, else: 0),
      retained_cents: if(classification == :retained_cents, do: settled_cents, else: 0),
      converted_cents: if(classification == :converted_cents, do: settled_cents, else: 0),
      credit_issued_cents: credit_issued_cents
    }
  end

  defp held_cash_rows(room_ids) do
    Repo.all(
      from rf in RoomFunding,
        join: r in Room,
        on: rf.room_id == r.id,
        join: f in CashFunding,
        on: rf.cash_funding_id == f.id,
        where: rf.room_id in ^room_ids and rf.kind == "cash" and rf.status == "held",
        order_by: [asc: f.id, asc: r.position],
        select: {rf, f}
    )
  end

  # The settled cash per funding, in funding (seniority) order: the
  # unattributed senior block first, then payments in commit order.
  defp moved_by_funding(cash_rows) do
    cash_rows
    |> Enum.reduce(%{}, fn {row, funding}, acc ->
      Map.update(acc, funding.id, {funding, row.amount_cents}, fn {funding, cents} ->
        {funding, cents + row.amount_cents}
      end)
    end)
    |> Enum.sort_by(fn {_id, {funding, _cents}} -> funding.id end)
    |> Enum.map(fn {_id, pair} -> pair end)
  end

  # Moves each funding's settled amount out of held cash into the
  # settlement's classification and settles the allocation rows.
  defp settle_cash_rows!(cash_rows, moved_by_funding, classification) do
    Enum.each(moved_by_funding, fn {funding, moved_cents} ->
      attrs =
        %{held_cents: funding.held_cents - moved_cents}
        |> Map.put(classification, Map.fetch!(funding, classification) + moved_cents)

      funding
      |> Changeset.change(attrs)
      |> Repo.update!()
    end)

    settle_rows!(for {row, _funding} <- cash_rows, do: row.id)
  end

  # The settled rooms' combined cash becomes a credit lot worth 110% of that
  # cash: the bonus is computed once on the combined amount under the
  # standard rounding rule, not separately per room. Each contributing
  # payment's entitlement is its share of the bonus-valued running totals in
  # funding order, so the entitlements telescope exactly to the issued lot.
  defp issue_credit_lot(_group, _occurred_on, _operation_id, []), do: 0

  defp issue_credit_lot(group, occurred_on, operation_id, moved_by_funding) do
    principal_cents = Enum.sum(for {_funding, cents} <- moved_by_funding, do: cents)
    lot_cents = principal_cents + percent_of(principal_cents, 10)

    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        original_cents: lot_cents,
        remaining_cents: lot_cents,
        expires_on: Date.add(occurred_on, @credit_lifetime_days)
      })
      |> Repo.insert!()

    insert_entitlements!(lot, moved_by_funding)

    lot_cents
  end

  defp insert_entitlements!(lot, contributions) do
    Enum.reduce(contributions, 0, fn {funding, cents}, running_cents ->
      entitlement_cents =
        cents + percent_of(running_cents + cents, 10) - percent_of(running_cents, 10)

      %CreditLotEntitlement{}
      |> CreditLotEntitlement.changeset(%{
        credit_lot_id: lot.id,
        cash_funding_id: funding.id,
        entitlement_cents: entitlement_cents
      })
      |> Repo.insert!()

      running_cents + cents
    end)

    :ok
  end

  # On a refundable cancellation, applied credit returns to its original lots
  # with the original expiry and never receives a second bonus; credit
  # returning to a shortfalled lot extinguishes unrecovered clawback before
  # any amount becomes available. On a non-refundable cancellation the credit
  # is consumed instead.
  defp settle_credit_rows!(room_ids, refundable) do
    rows =
      Repo.all(
        from rf in RoomFunding,
          join: a in CreditApplication,
          on: rf.credit_application_id == a.id,
          join: l in CreditLot,
          on: a.credit_lot_id == l.id,
          where: rf.room_id in ^room_ids and rf.kind == "credit" and rf.status == "held",
          select: {rf, l}
      )

    if refundable do
      rows
      |> Enum.group_by(fn {_row, lot} -> lot.id end)
      |> Enum.each(fn {_lot_id, lot_rows} ->
        {_row, lot} = hd(lot_rows)
        restored_cents = Enum.sum(for {row, _lot} <- lot_rows, do: row.amount_cents)
        absorbed_cents = min(restored_cents, lot.unrecovered_clawback_cents)

        lot
        |> Changeset.change(
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed_cents,
          remaining_cents: lot.remaining_cents + restored_cents - absorbed_cents
        )
        |> Repo.update!()
      end)
    end

    settle_rows!(for {row, _lot} <- rows, do: row.id)
  end

  defp settle_rows!([]), do: :ok

  defp settle_rows!(row_ids) do
    Repo.update_all(from(rf in RoomFunding, where: rf.id in ^row_ids), set: [status: "settled"])
    :ok
  end

  defp settle_rooms!(rooms, cash_rows, classification) do
    cash_by_room =
      Enum.reduce(cash_rows, %{}, fn {row, _funding}, acc ->
        Map.update(acc, row.room_id, row.amount_cents, &(&1 + row.amount_cents))
      end)

    Enum.each(rooms, fn room ->
      cash_cents = Map.get(cash_by_room, room.id, 0)

      room
      |> Changeset.change(%{
        status: "cancelled",
        refunded_cents: if(classification == :refunded_cents, do: cash_cents, else: 0),
        retained_cents: if(classification == :retained_cents, do: cash_cents, else: 0),
        cash_converted_cents: if(classification == :converted_cents, do: cash_cents, else: 0)
      })
      |> Repo.update!()
    end)

    :ok
  end

  ## reduce_cash_payment

  defp reduce_cash_payment(operation) do
    case resolve_payment_target(operation, :reduce) do
      {:ok, record, funding, group} ->
        # The addressed group is the original payment's group.
        operation = Map.put(operation, "group_id", group.group_id)

        with :ok <- check_revision(operation, group),
             {:ok, amount_cents} <- payment_amount(Map.get(operation, "amount_cents")),
             :ok <- ensure_within_held(funding, amount_cents) do
          remove_held_allocations(funding, amount_cents)

          funding
          |> Changeset.change(
            held_cents: funding.held_cents - amount_cents,
            reduced_cents: funding.reduced_cents + amount_cents
          )
          |> Repo.update!()

          totals = refresh_group_totals(group)

          group =
            update_group!(
              group,
              Map.merge(totals, %{cash_reduced_cents: group.cash_reduced_cents + amount_cents})
            )

          applied(operation, %{
            payment_operation_id: record.operation_id,
            group_id: group.group_id,
            amount_cents: amount_cents,
            outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents,
            revision: group.revision
          })
        else
          error -> rejection_for(operation, error)
        end

      {:error, _code} = error ->
        rejection_for(operation, error)
    end
  end

  # Only cash from the target payment that is still held on active rooms can
  # be reduced; cash already refunded, retained, or converted to hotel credit
  # is settled history.
  defp ensure_reducible(record) do
    if applied_cash_payment?(record) do
      case Repo.get_by(CashFunding, operation_id: record.operation_id) do
        %CashFunding{held_cents: held_cents} = funding when held_cents > 0 -> {:ok, funding}
        _other -> {:error, "payment_not_reducible"}
      end
    else
      {:error, "payment_not_reducible"}
    end
  end

  defp ensure_within_held(funding, amount_cents) do
    if amount_cents <= funding.held_cents do
      :ok
    else
      {:error, "reduction_exceeds_held_cash"}
    end
  end

  ## charge_back_payment

  defp charge_back_payment(operation) do
    case resolve_payment_target(operation, :chargeback) do
      {:ok, record, funding, group} ->
        # The addressed group is the original payment's group.
        operation = Map.put(operation, "group_id", group.group_id)

        with :ok <- check_revision(operation, group) do
          do_charge_back(operation, record, funding, group)
        else
          error -> rejection_for(operation, error)
        end

      {:error, _code} = error ->
        rejection_for(operation, error)
    end
  end

  # A payment can be charged back whether its group is active or cancelled,
  # as long as it is an applied cash payment that was neither fully reduced
  # nor already charged back.
  defp ensure_chargeable(record) do
    if applied_cash_payment?(record) do
      case Repo.get_by(CashFunding, operation_id: record.operation_id) do
        %CashFunding{} = funding ->
          chargeable_cents =
            funding.held_cents + funding.refunded_cents + funding.retained_cents +
              funding.converted_cents

          if funding.charged_back_cents == 0 and chargeable_cents > 0 do
            {:ok, funding}
          else
            {:error, "payment_not_chargeable"}
          end

        nil ->
          {:error, "payment_not_chargeable"}
      end
    else
      {:error, "payment_not_chargeable"}
    end
  end

  # Reverses all cash from the payment except any portion already recorded as
  # reduced: held allocations are removed in reverse fill order, refunded and
  # retained portions are reclassified, and converted principal moves to
  # charged-back cash while the credit entitlement it created is revoked.
  defp do_charge_back(operation, record, funding, group) do
    remove_held_allocations(funding, funding.held_cents)
    revoke_entitlements(funding)

    charged_back_cents =
      funding.held_cents + funding.refunded_cents + funding.retained_cents +
        funding.converted_cents

    funding
    |> Changeset.change(
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_cents: 0,
      charged_back_cents: funding.charged_back_cents + charged_back_cents
    )
    |> Repo.update!()

    totals = refresh_group_totals(group)

    group =
      update_group!(
        group,
        Map.merge(totals, %{
          refunded_cents: group.refunded_cents - funding.refunded_cents,
          retained_cents: group.retained_cents - funding.retained_cents,
          cash_converted_cents: group.cash_converted_cents - funding.converted_cents,
          cash_charged_back_cents: group.cash_charged_back_cents + charged_back_cents
        })
      )

    applied(operation, %{
      payment_operation_id: record.operation_id,
      group_id: group.group_id,
      charged_back_cents: charged_back_cents,
      outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents,
      revision: group.revision
    })
  end

  # Revokes the credit entitlement the payment's converted cash created:
  # each lot's remaining balance absorbs the revocation first, and any amount
  # that cannot be removed becomes that lot's unrecovered clawback.
  defp revoke_entitlements(funding) do
    entitlements =
      Repo.all(
        from e in CreditLotEntitlement,
          where: e.cash_funding_id == ^funding.id and e.revoked_cents < e.entitlement_cents,
          preload: [:credit_lot]
      )

    Enum.each(entitlements, fn entitlement ->
      lot = entitlement.credit_lot
      revoked_cents = entitlement.entitlement_cents - entitlement.revoked_cents
      removed_cents = min(lot.remaining_cents, revoked_cents)

      lot
      |> Changeset.change(
        remaining_cents: lot.remaining_cents - removed_cents,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + revoked_cents - removed_cents
      )
      |> Repo.update!()

      entitlement
      |> Changeset.change(revoked_cents: entitlement.revoked_cents + revoked_cents)
      |> Repo.update!()
    end)

    :ok
  end

  # Removes held allocations of the funding in reverse fill order, so the
  # active rooms' outstanding deposit reopens by the amount removed.
  defp remove_held_allocations(funding, amount_cents) do
    rows =
      Repo.all(
        from rf in RoomFunding,
          join: r in Room,
          on: rf.room_id == r.id,
          where: rf.cash_funding_id == ^funding.id and rf.status == "held",
          order_by: [desc: r.position],
          select: rf
      )

    Enum.reduce(rows, amount_cents, fn row, left ->
      cond do
        left == 0 ->
          0

        row.amount_cents <= left ->
          Repo.delete!(row)
          left - row.amount_cents

        true ->
          row
          |> Changeset.change(amount_cents: row.amount_cents - left)
          |> Repo.update!()

          0
      end
    end)

    :ok
  end

  ## Payment targeting

  # Resolves the durable record, its classification, and the addressed group
  # for reduce_cash_payment and charge_back_payment. Group existence is
  # resolved before revisions are compared; a target that can never accept
  # the operation is rejected before either.
  defp resolve_payment_target(operation, classification) do
    with {:ok, record} <- fetch_payment_record(operation),
         {:ok, funding} <- classify_payment(record, classification),
         {:ok, group} <- fetch_record_group(record) do
      {:ok, record, funding, group}
    end
  end

  defp classify_payment(record, :reduce), do: ensure_reducible(record)
  defp classify_payment(record, :chargeback), do: ensure_chargeable(record)

  defp fetch_payment_record(operation) do
    case Map.get(operation, "payment_operation_id") do
      payment_operation_id when is_binary(payment_operation_id) ->
        case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
          nil -> {:error, "operation_not_found"}
          %OperationRecord{} = record -> {:ok, record}
        end

      _other ->
        {:error, "invalid_operation"}
    end
  end

  defp fetch_record_group(record) do
    group_id =
      cond do
        is_map(record.result) and is_binary(record.result["group_id"]) ->
          record.result["group_id"]

        is_map(record.submission) and is_binary(record.submission["group_id"]) ->
          record.submission["group_id"]

        true ->
          nil
      end

    case group_id && Repo.get_by(Group, group_id: group_id) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, "group_not_found"}
    end
  end

  ## Legacy funding backfill (run by the room-accounting migration)

  @doc """
  Brings funding recorded before durable operation records existed forward as
  one unattributed senior block per group — its aggregate cash first, then
  its hotel-credit lots in original consumption order — ahead of the funding
  represented by durable operation records, which is allocated afterward in
  durable-record commit order. Creating the room allocations changes no
  aggregate cash, credit, or liability balance.
  """
  def bring_forward_legacy_funding do
    groups = Repo.all(from g in Group, order_by: [asc: g.inserted_at, asc: g.id])

    Enum.each(groups, &bring_forward_group/1)
  end

  defp bring_forward_group(group) do
    payment_records = applied_records(group.group_id, "record_cash_payment")
    apply_records = applied_records(group.group_id, "apply_hotel_credit")

    legacy_cash_cents =
      group.cash_paid_cents -
        Enum.sum(for record <- payment_records, do: record.result["amount_cents"])

    legacy_funding =
      if legacy_cash_cents > 0 do
        insert_cash_funding!(%{
          group_id: group.id,
          operation_id: nil,
          amount_cents: legacy_cash_cents,
          held_cents: legacy_cash_cents
        })
      end

    durable_fundings =
      Map.new(payment_records, fn record ->
        funding =
          insert_cash_funding!(%{
            group_id: group.id,
            operation_id: record.operation_id,
            amount_cents: record.result["amount_cents"],
            held_cents: record.result["amount_cents"]
          })

        {record.id, funding}
      end)

    {attributed_apps, legacy_apps} = attribute_applications(group, apply_records)

    case group.status do
      "active" ->
        entries =
          [{:cash, legacy_funding}] ++
            Enum.map(legacy_apps, &{:credit, &1}) ++
            durable_entries(payment_records, apply_records, durable_fundings, attributed_apps)

        entries
        |> Enum.reject(fn {_kind, source} -> is_nil(source) end)
        |> allocate_backfilled_rooms(group)

      "cancelled" ->
        settle_backfilled_group(group, legacy_funding, durable_fundings)
    end
  end

  defp insert_cash_funding!(attrs) do
    %CashFunding{} |> CashFunding.changeset(attrs) |> Repo.insert!()
  end

  defp applied_records(group_id, type) do
    Repo.all(
      from r in OperationRecord,
        where: r.type == ^type,
        order_by: [asc: r.id]
    )
    |> Enum.filter(fn record ->
      is_map(record.result) and record.result["status"] == "applied" and
        is_map(record.submission) and record.submission["group_id"] == group_id
    end)
  end

  # Attributes credit applications to the durable apply_hotel_credit records
  # that created them. Applications have no recorded operation identity from
  # before this release, so the newest applications are matched to the newest
  # records; what remains is the unattributed senior block, ordered by lot
  # expiry and then source operation, mirroring original consumption order.
  defp attribute_applications(group, apply_records) do
    applications =
      Repo.all(
        from a in CreditApplication,
          where: a.group_id == ^group.id,
          preload: [:credit_lot]
      )
      |> Enum.sort_by(fn application ->
        {
          application.inserted_at,
          application.credit_lot.expires_on,
          application.credit_lot.source_operation_id || "",
          application.id
        }
      end)

    {attributed, remaining} =
      apply_records
      |> Enum.sort_by(& &1.id, :desc)
      |> Enum.map_reduce(applications, fn record, pool ->
        {taken, rest} = take_applications_from_end(pool, record.result["amount_cents"], [])
        {{record.id, taken}, rest}
      end)

    legacy_credit_cents =
      group.credit_paid_cents -
        Enum.sum(for record <- apply_records, do: record.result["amount_cents"])

    legacy_pool_cents = Enum.sum(for application <- remaining, do: application.amount_cents)

    if legacy_credit_cents != legacy_pool_cents do
      raise "credit applications for group #{group.group_id} do not match its recorded funding"
    end

    {Map.new(attributed), remaining}
  end

  defp take_applications_from_end(pool, amount_cents, taken) do
    cond do
      amount_cents == 0 ->
        {taken, pool}

      pool == [] ->
        raise "credit applications do not cover the recorded apply_hotel_credit amounts"

      true ->
        application = List.last(pool)

        if application.amount_cents > amount_cents do
          raise "credit applications do not align with the recorded apply_hotel_credit amounts"
        end

        take_applications_from_end(
          Enum.drop(pool, -1),
          amount_cents - application.amount_cents,
          [application | taken]
        )
    end
  end

  # Durable funding in durable-record commit order, regardless of
  # occurred_on: applied cash payments and hotel-credit applications
  # classified by the retained operation type.
  defp durable_entries(payment_records, apply_records, durable_fundings, attributed_apps) do
    (payment_records ++ apply_records)
    |> Enum.sort_by(& &1.id)
    |> Enum.flat_map(fn record ->
      case record.type do
        "record_cash_payment" ->
          [{:cash, Map.fetch!(durable_fundings, record.id)}]

        "apply_hotel_credit" ->
          Enum.map(Map.get(attributed_apps, record.id, []), &{:credit, &1})
      end
    end)
  end

  defp allocate_backfilled_rooms(entries, group) do
    rooms = Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: [asc: r.position])
    remaining = Map.new(rooms, fn room -> {room.id, room.deposit_due_cents} end)

    Enum.reduce(entries, remaining, fn {kind, source}, remaining ->
      {remaining, left} =
        Enum.reduce(rooms, {remaining, source.amount_cents}, fn room, {remaining, left} ->
          take_cents = min(Map.fetch!(remaining, room.id), left)

          if take_cents > 0 do
            insert_room_funding!(room, {kind, source}, take_cents)
            {Map.put(remaining, room.id, remaining[room.id] - take_cents), left - take_cents}
          else
            {remaining, left}
          end
        end)

      if left != 0 do
        raise "recorded funding exceeds the room deposits of group #{group.group_id}"
      end

      remaining
    end)

    :ok
  end

  # A group cancelled before this release settled all of its rooms and cash
  # with one classification; bring its fundings, rooms, and credit
  # entitlements to the state that settlement implies.
  defp settle_backfilled_group(group, legacy_funding, durable_fundings) do
    classification =
      cond do
        group.cash_converted_cents > 0 -> :converted_cents
        group.refunded_cents > 0 -> :refunded_cents
        group.retained_cents > 0 -> :retained_cents
        true -> nil
      end

    fundings =
      [legacy_funding | durable_fundings |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))]
      |> Enum.reject(&is_nil/1)

    Enum.each(fundings, fn funding ->
      if classification && funding.held_cents > 0 do
        funding
        |> Changeset.change(%{held_cents: 0} |> Map.put(classification, funding.held_cents))
        |> Repo.update!()
      end
    end)

    rooms = Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: [asc: r.position])
    cash_by_room = backfilled_room_cash(rooms, fundings)

    Enum.each(rooms, fn room ->
      cash_cents = Map.get(cash_by_room, room.id, 0)

      room
      |> Changeset.change(%{
        status: "cancelled",
        refunded_cents: if(classification == :refunded_cents, do: cash_cents, else: 0),
        retained_cents: if(classification == :retained_cents, do: cash_cents, else: 0),
        cash_converted_cents: if(classification == :converted_cents, do: cash_cents, else: 0)
      })
      |> Repo.update!()
    end)

    if classification == :converted_cents do
      case conversion_lot(group) do
        %CreditLot{} = lot ->
          insert_entitlements!(lot, for(funding <- fundings, do: {funding, funding.amount_cents}))

        nil ->
          :ok
      end
    end

    # Group totals describe active rooms only; a cancelled group has none.
    group
    |> Changeset.change(%{
      lodging_total_cents: 0,
      deposit_due_cents: 0,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0
    })
    |> Repo.update!()

    :ok
  end

  # The room-level settled cash implied by filling the rooms in their
  # original order with the group's fundings in seniority order.
  defp backfilled_room_cash(rooms, fundings) do
    remaining = Map.new(rooms, fn room -> {room.id, room.deposit_due_cents} end)

    {_remaining, cash_by_room} =
      Enum.reduce(fundings, {remaining, %{}}, fn funding, {remaining, cash_by_room} ->
        {remaining, cash_by_room, _left} =
          Enum.reduce(rooms, {remaining, cash_by_room, funding.amount_cents}, fn room,
                                                                                 {remaining,
                                                                                  cash_by_room,
                                                                                  left} ->
            take_cents = min(Map.fetch!(remaining, room.id), left)

            {
              Map.put(remaining, room.id, remaining[room.id] - take_cents),
              Map.update(cash_by_room, room.id, take_cents, &(&1 + take_cents)),
              left - take_cents
            }
          end)

        {remaining, cash_by_room}
      end)

    cash_by_room
  end

  # The credit lot issued by this group's cancellation, when that
  # cancellation was durably recorded.
  defp conversion_lot(group) do
    cancel_record =
      Repo.all(from r in OperationRecord, where: r.type == "cancel_group", order_by: [asc: r.id])
      |> Enum.find(fn record ->
        is_map(record.result) and record.result["status"] == "applied" and
          is_map(record.submission) and record.submission["group_id"] == group.group_id
      end)

    case cancel_record do
      nil -> nil
      record -> Repo.get_by(CreditLot, source_operation_id: record.operation_id)
    end
  end

  ## Shared validation and persistence

  defp fetch_group(operation) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> {:error, "group_not_found"}
          %Group{} = group -> {:ok, group}
        end

      _other ->
        {:error, "invalid_operation"}
    end
  end

  # Group existence is resolved before revisions are compared, and a stale
  # revision is rejected before any other domain rule is evaluated.
  defp check_revision(operation, group) do
    case Map.get(operation, "expected_revision") do
      nil ->
        :ok

      expected_revision ->
        if expected_revision == group.revision do
          :ok
        else
          {:error, "stale_revision",
           %{expected_revision: expected_revision, actual_revision: group.revision}}
        end
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(%Group{}), do: {:error, "group_not_active"}

  defp require_fields(operation, fields) do
    if Enum.all?(fields, &is_binary(Map.get(operation, &1))) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp fetch_occurred_on(operation) do
    case parse_date(Map.get(operation, "occurred_on")) do
      {:ok, occurred_on} -> {:ok, occurred_on}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp ensure_group_absent(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp stay_dates(operation) do
    with {:ok, arrival_on} <- parse_date(Map.get(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(Map.get(operation, "departure_on")),
         :gt <- Date.compare(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on}
    else
      _other -> {:error, "invalid_stay"}
    end
  end

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {:ok, rooms}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp valid_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp valid_room?(room) do
    is_map(room) and is_binary(Map.get(room, "room_id")) and
      is_integer(Map.get(room, "nightly_rate_cents")) and
      Map.get(room, "nightly_rate_cents") >= 0
  end

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, &Map.get(&1, "room_id"))
    length(room_ids) == length(Enum.uniq(room_ids))
  end

  defp valid_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp valid_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_string(date)

  # Every applied operation addressed to a group increments its revision
  # exactly once, even when no booking field visibly changes.
  defp update_group!(group, attrs) do
    group
    |> Changeset.change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  ## Operation results

  defp applied(operation, fields) do
    result =
      Map.merge(
        %{operation_id: Map.get(operation, "operation_id"), status: "applied"},
        fields
      )

    {:ok, result}
  end

  defp rejection_for(operation, {:error, code}), do: rejected(operation, code)

  defp rejection_for(operation, {:error, code, extra}),
    do: rejected(operation, code, extra)

  defp rejected(operation, code, extra \\ %{}) do
    result = %{
      operation_id: Map.get(operation, "operation_id"),
      status: "rejected",
      code: code
    }

    result =
      case Map.get(operation, "group_id") do
        group_id when is_binary(group_id) -> Map.put(result, :group_id, group_id)
        _other -> result
      end

    {:error, Map.merge(result, extra)}
  end
end
