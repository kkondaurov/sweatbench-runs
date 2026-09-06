defmodule GroupStay.Groups do
  @moduledoc """
  The Groups context owns group reservations: opening them, recording cash and
  hotel credit against their deposits, moving held funding between a guest's
  groups, rescheduling their stays, and cancelling all or part of them, as
  well as the credit lots and finance totals derived from those records.

  Cash and credit fund active room deposits in the rooms' original order,
  filling one room's deposit before moving to the next. Every recorded cash
  payment is tracked as a cash funding whose disposition (held, refunded,
  retained, converted, reduced, or charged back) is always fully accounted
  for, so one payment can be reconciled exactly against the group, room, and
  ledger views.

  Finance reporting rests on a durable inception point: the first applied
  `start_finance_reporting` operation snapshots the opening position on its
  `starts_on` date, and every applied operation afterwards records its
  funding movements with the posting date that is the later of its own
  `occurred_on` and that start date. The daily report folds those movements
  into per-property held-cash and company-wide credit-liability movements,
  deriving credit expiries that need no partner operation.

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
    FundingMovement,
    Group,
    OperationRecord,
    ReportingState,
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
    statement = %{
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

    # Once any funding from the payment has participated in a transfer, the
    # statement breaks its held cash down by holding group.
    if funding.transferred do
      Map.put(statement, :held_by_group, held_by_group(funding))
    else
      statement
    end
  end

  defp held_by_group(funding) do
    Repo.all(
      from rf in RoomFunding,
        join: r in Room,
        on: rf.room_id == r.id,
        join: g in Group,
        on: r.group_id == g.id,
        where: rf.cash_funding_id == ^funding.id and rf.status == "held",
        group_by: g.group_id,
        order_by: g.group_id,
        select: %{group_id: g.group_id, amount_cents: sum(rf.amount_cents)}
    )
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

  defp do_apply(%{"type" => "transfer_deposit"} = operation), do: transfer_deposit(operation)

  defp do_apply(%{"type" => "start_finance_reporting"} = operation),
    do: start_finance_reporting(operation)

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

      record_movement(operation, movement_date(operation), "cash", "received", amount_cents,
        property_id: group.property_id
      )

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

        record_movement(
          operation,
          occurred_on,
          "credit",
          "applied_credit",
          take_cents,
          detail: %{"lot_id" => lot.id}
        )
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

    lot =
      if classification == :converted_cents do
        issue_credit_lot(group, occurred_on, Map.get(operation, "operation_id"), moved_by_funding)
      else
        nil
      end

    {consumed_cents, restores} = settle_credit_rows!(room_ids, refundable)
    settle_rooms!(rooms, cash_rows, classification)

    record_settlement_movements(
      operation,
      group,
      occurred_on,
      classification,
      moved_by_funding,
      lot,
      consumed_cents,
      restores
    )

    %{
      refunded_cents: if(classification == :refunded_cents, do: settled_cents, else: 0),
      retained_cents: if(classification == :retained_cents, do: settled_cents, else: 0),
      converted_cents: if(classification == :converted_cents, do: settled_cents, else: 0),
      credit_issued_cents: if(lot, do: lot.original_cents, else: 0)
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
  defp issue_credit_lot(_group, _occurred_on, _operation_id, []), do: nil

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

    lot
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
  # any amount becomes available, and credit returning to a lot whose expiry
  # has already passed on the cancellation date expires immediately. On a
  # non-refundable cancellation the credit is consumed instead. Returns the
  # consumed total and one {lot, restored_cents, absorbed_cents} entry per
  # lot that received a restoration.
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

    restores =
      if refundable do
        rows
        |> Enum.group_by(fn {_row, lot} -> lot.id end)
        |> Enum.map(fn {_lot_id, lot_rows} ->
          {_row, lot} = hd(lot_rows)
          restored_cents = Enum.sum(for {row, _lot} <- lot_rows, do: row.amount_cents)
          absorbed_cents = min(restored_cents, lot.unrecovered_clawback_cents)

          lot
          |> Changeset.change(
            unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed_cents,
            remaining_cents: lot.remaining_cents + restored_cents - absorbed_cents
          )
          |> Repo.update!()

          {lot, restored_cents, absorbed_cents}
        end)
      else
        []
      end

    settle_rows!(for {row, _lot} <- rows, do: row.id)

    consumed_cents =
      if refundable, do: 0, else: Enum.sum(for {row, _lot} <- rows, do: row.amount_cents)

    {consumed_cents, restores}
  end

  defp settle_rows!([]), do: :ok

  defp settle_rows!(row_ids) do
    Repo.update_all(from(rf in RoomFunding, where: rf.id in ^row_ids), set: [status: "settled"])
    :ok
  end

  # Records the settlement's report movements. Settled cash moves under its
  # classification at the property where it is settled, tagged with the
  # funding's payment identity so a later chargeback can follow it there; a
  # conversion additionally issues its credit lot. Consumed credit leaves the
  # liability; restored credit returns to its lot unless shortfall absorbs it
  # or its expiry has already passed on the cancellation date, in which case
  # it expires immediately.
  defp record_settlement_movements(
         operation,
         group,
         occurred_on,
         classification,
         moved_by_funding,
         lot,
         consumed_cents,
         restores
       ) do
    movement_classification =
      case classification do
        :refunded_cents -> "refunded"
        :retained_cents -> "retained"
        :converted_cents -> "converted_to_credit"
      end

    Enum.each(moved_by_funding, fn {funding, cents} ->
      if cents > 0 do
        record_movement(
          operation,
          occurred_on,
          "cash",
          movement_classification,
          cents,
          property_id: group.property_id,
          detail: %{"funding_operation_id" => funding.operation_id}
        )
      end
    end)

    if lot do
      record_movement(operation, occurred_on, "credit", "issued", lot.original_cents,
        detail: %{"lot_id" => lot.id, "expires_on" => Date.to_string(lot.expires_on)}
      )
    end

    if consumed_cents > 0 do
      record_movement(operation, occurred_on, "credit", "consumed", consumed_cents)
    end

    Enum.each(restores, fn {lot, restored_cents, absorbed_cents} ->
      if absorbed_cents > 0 do
        record_movement(operation, occurred_on, "credit", "absorbed", absorbed_cents,
          detail: %{"lot_id" => lot.id}
        )
      end

      net_cents = restored_cents - absorbed_cents

      if net_cents > 0 do
        if Date.compare(lot.expires_on, occurred_on) == :lt do
          record_movement(operation, occurred_on, "credit", "expired", net_cents,
            detail: %{"lot_id" => lot.id, "immediate" => true}
          )
        else
          record_movement(operation, occurred_on, "credit", "restored_credit", net_cents,
            detail: %{"lot_id" => lot.id}
          )
        end
      end
    end)

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
          removed_by_group = remove_held_allocations(funding, amount_cents)

          funding
          |> Changeset.change(
            held_cents: funding.held_cents - amount_cents,
            reduced_cents: funding.reduced_cents + amount_cents
          )
          |> Repo.update!()

          properties = bump_changed_groups(removed_by_group, group)
          record_correction_movements(operation, "reduced", removed_by_group, properties)

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
    removed_by_group = remove_held_allocations(funding, funding.held_cents)
    properties = bump_changed_groups(removed_by_group, group)
    revoke_entitlements(operation, funding)
    record_charge_back_movements(operation, funding, removed_by_group, properties, group)

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

  # Records the chargeback's cash movements at the properties where the cash
  # is held or was settled. The held part actually leaves those properties'
  # held balances, so it reports positive charged-back cash only. The
  # settled parts were reported under their original classification earlier;
  # reclassifying them without touching any held balance reports a negative
  # amount under that classification together with positive charged-back
  # cash, at the property where they settled (cash settled before movements
  # existed is attributed to the payment's original group).
  defp record_charge_back_movements(operation, funding, removed_by_group, properties, group) do
    occurred_on = movement_date(operation)

    Enum.each(removed_by_group, fn {group_id, cents} ->
      record_movement(operation, occurred_on, "cash", "charged_back", cents,
        property_id: Map.fetch!(properties, group_id)
      )
    end)

    for {classification, field} <- [
          {"refunded", :refunded_cents},
          {"retained", :retained_cents},
          {"converted_to_credit", :converted_cents}
        ],
        total = Map.fetch!(funding, field),
        total > 0,
        {property_id, cents} <- settled_properties(funding, classification, total, group) do
      record_movement(operation, occurred_on, "cash", classification, -cents,
        property_id: property_id
      )

      record_movement(operation, occurred_on, "cash", "charged_back", cents,
        property_id: property_id
      )
    end

    :ok
  end

  # The properties where one classification of the funding's cash settled,
  # from its recorded settlement movements; any amount settled before
  # movements existed belongs to the payment's original group.
  defp settled_properties(funding, classification, total_cents, group) do
    rows =
      Repo.all(
        from m in FundingMovement,
          where:
            m.classification == ^classification and
              fragment("json_extract(?, '$.funding_operation_id')", m.detail) ==
                ^funding.operation_id,
          group_by: m.property_id,
          select: {m.property_id, sum(m.amount_cents)}
      )

    recorded_cents = Enum.sum(for {_property, cents} <- rows, do: cents)

    rows
    |> Map.new()
    |> add_cents(group.property_id, total_cents - recorded_cents)
    |> Enum.reject(fn {_property, cents} -> cents == 0 end)
  end

  # Revokes the credit entitlement the payment's converted cash created:
  # each lot's remaining balance absorbs the revocation first, and any amount
  # that cannot be removed becomes that lot's unrecovered clawback. Only the
  # amount actually removed leaves the credit liability at revocation time;
  # the clawback part leaves it later through absorption or consumption.
  defp revoke_entitlements(operation, funding) do
    entitlements =
      Repo.all(
        from e in CreditLotEntitlement,
          where: e.cash_funding_id == ^funding.id and e.revoked_cents < e.entitlement_cents,
          preload: [:credit_lot]
      )

    occurred_on = movement_date(operation)

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

      if removed_cents > 0 do
        record_movement(operation, occurred_on, "credit", "revoked", removed_cents,
          detail: %{"lot_id" => lot.id, "revoked_cents" => revoked_cents}
        )
      end
    end)

    :ok
  end

  # Removes held allocations of the funding in reverse allocation order —
  # the most recently created allocation first, across every group the
  # funding's allocations may have moved to — so the active rooms'
  # outstanding deposit reopens by the amount removed. Returns the removed
  # cents grouped by the internal id of the group holding them.
  defp remove_held_allocations(funding, amount_cents) do
    rows = held_allocation_rows(funding)

    room_groups =
      Repo.all(
        from r in Room,
          where: r.id in ^Enum.map(rows, & &1.room_id),
          select: {r.id, r.group_id}
      )
      |> Map.new()

    {_left, removed_by_group} =
      Enum.reduce(rows, {amount_cents, %{}}, fn row, {left, removed} ->
        group_id = Map.fetch!(room_groups, row.room_id)

        cond do
          left == 0 ->
            {0, removed}

          row.amount_cents <= left ->
            Repo.delete!(row)
            {left - row.amount_cents, add_cents(removed, group_id, row.amount_cents)}

          true ->
            row
            |> Changeset.change(amount_cents: row.amount_cents - left)
            |> Repo.update!()

            {0, add_cents(removed, group_id, left)}
        end
      end)

    removed_by_group
  end

  # The funding's held allocation rows ordered by creation order descending
  # (SQLite rowid): the most recently created allocation first.
  defp held_allocation_rows(funding) do
    Repo.all(
      from rf in RoomFunding,
        where: rf.cash_funding_id == ^funding.id and rf.status == "held",
        order_by: [desc: fragment("rowid")],
        select: rf
    )
  end

  defp add_cents(amounts, key, cents), do: Map.update(amounts, key, cents, &(&1 + cents))

  # Refreshes the totals and increments the revision of every group whose
  # held funding changed, beyond the operation's addressed group. Revision
  # guards remain preconditions only for explicitly addressed groups, but an
  # applied operation increments the revision of every group it changes.
  # Returns %{group_id => property_id} for the affected groups.
  defp bump_changed_groups(amounts_by_group, addressed_group) do
    Map.new(amounts_by_group, fn {group_id, _cents} ->
      if group_id == addressed_group.id do
        {group_id, addressed_group.property_id}
      else
        group = Repo.get!(Group, group_id)
        update_group!(group, refresh_group_totals(group))
        {group_id, group.property_id}
      end
    end)
  end

  # Records one correction movement per property where the removed cash is
  # currently held: a later correction follows the affected cash to the
  # property where it is held, not back to the payment's original property.
  defp record_correction_movements(operation, classification, amounts_by_group, properties) do
    occurred_on = movement_date(operation)

    Enum.each(amounts_by_group, fn {group_id, cents} ->
      record_movement(operation, occurred_on, "cash", classification, cents,
        property_id: Map.fetch!(properties, group_id)
      )
    end)

    :ok
  end

  ## transfer_deposit

  defp transfer_deposit(operation) do
    with {:ok, source} <- fetch_named_group(operation, "source_group_id"),
         {:ok, destination} <- fetch_named_group(operation, "destination_group_id"),
         :ok <- check_named_revision(operation, "expected_revision", source),
         :ok <- check_named_revision(operation, "destination_expected_revision", destination),
         :ok <- ensure_transferable(source, destination),
         :ok <- ensure_active_named(source),
         :ok <- ensure_active_named(destination),
         {:ok, amount_cents} <- payment_amount(Map.get(operation, "amount_cents")),
         :ok <- ensure_within_held_funding(source, amount_cents),
         :ok <- ensure_transfer_outstanding(destination, amount_cents) do
      do_transfer(operation, source, destination, amount_cents)
    else
      error -> rejection_for(operation, error)
    end
  end

  # Moves held funding out of the source's active-room allocations in
  # reverse allocation order — the most recently created allocation first,
  # regardless of funding kind — preserving each unit's provenance, and fills
  # the destination's active rooms in their original order in the order the
  # units were drawn. Nothing is settled or revalued; only which active
  # rooms hold the funding changes.
  defp do_transfer(operation, source, destination, amount_cents) do
    draws = draw_held_allocations(source, amount_cents)

    Enum.each(draws, fn {row, take_cents} ->
      if take_cents == row.amount_cents do
        Repo.delete!(row)
      else
        row
        |> Changeset.change(amount_cents: row.amount_cents - take_cents)
        |> Repo.update!()
      end
    end)

    units =
      Enum.map(draws, fn {row, take_cents} ->
        {row.kind, row.cash_funding_id, row.credit_application_id, take_cents}
      end)

    fill_transfer_destination(destination, units)
    flag_transferred_fundings(draws)

    moved_cash_cents = Enum.sum(for {"cash", _f, _a, cents} <- units, do: cents)
    moved_credit_cents = Enum.sum(for {"credit", _f, _a, cents} <- units, do: cents)

    if moved_cash_cents > 0 do
      record_movement(
        operation,
        movement_date(operation),
        "cash",
        "transferred",
        moved_cash_cents,
        property_id: source.property_id,
        detail: %{
          "destination_property_id" => destination.property_id,
          "cash_cents" => moved_cash_cents,
          "credit_cents" => moved_credit_cents
        }
      )
    end

    source_totals = refresh_group_totals(source)
    source = update_group!(source, source_totals)

    destination_totals = refresh_group_totals(destination)
    destination = update_group!(destination, destination_totals)

    applied(operation, %{
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount_cents,
      source_outstanding_deposit_cents:
        source_totals.deposit_due_cents - source_totals.deposit_paid_cents,
      destination_outstanding_deposit_cents:
        destination_totals.deposit_due_cents - destination_totals.deposit_paid_cents,
      source_revision: source.revision,
      destination_revision: destination.revision
    })
  end

  # The source's held allocations in reverse allocation order, paired with
  # the amount drawn from each.
  defp draw_held_allocations(group, amount_cents) do
    room_ids = Repo.all(from r in Room, where: r.group_id == ^group.id, select: r.id)

    rows =
      Repo.all(
        from rf in RoomFunding,
          where: rf.room_id in ^room_ids and rf.status == "held",
          order_by: [desc: fragment("rowid")],
          select: rf
      )

    {draws, left} =
      Enum.map_reduce(rows, amount_cents, fn row, left ->
        take_cents = min(row.amount_cents, left)
        {{row, take_cents}, left - take_cents}
      end)

    if left != 0 do
      raise "held funding of group #{group.group_id} does not cover the transfer"
    end

    for {row, take_cents} <- draws, take_cents > 0, do: {row, take_cents}
  end

  # Fills the destination's active rooms in their original order with the
  # drawn units, preserving the order in which the units were drawn.
  defp fill_transfer_destination(destination, units) do
    rooms = active_rooms(destination.id)

    left_units =
      Enum.reduce(rooms, units, fn room, pending ->
        remaining_cents = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents

        {pending, _left} =
          Enum.map_reduce(pending, remaining_cents, fn {kind, funding_id, application_id, cents},
                                                       left ->
            take_cents = min(cents, left)

            if take_cents > 0 do
              insert_transfer_funding!(room, kind, funding_id, application_id, take_cents)
            end

            {{kind, funding_id, application_id, cents - take_cents}, left - take_cents}
          end)

        Enum.reject(pending, fn {_kind, _funding_id, _application_id, cents} -> cents == 0 end)
      end)

    if left_units != [] do
      raise "transferred funding exceeds the outstanding deposit of group #{destination.group_id}"
    end

    :ok
  end

  defp insert_transfer_funding!(room, "cash", cash_funding_id, _application_id, amount_cents) do
    %RoomFunding{}
    |> RoomFunding.changeset(%{
      room_id: room.id,
      kind: "cash",
      status: "held",
      amount_cents: amount_cents,
      cash_funding_id: cash_funding_id
    })
    |> Repo.insert!()
  end

  defp insert_transfer_funding!(room, "credit", _funding_id, application_id, amount_cents) do
    %RoomFunding{}
    |> RoomFunding.changeset(%{
      room_id: room.id,
      kind: "credit",
      status: "held",
      amount_cents: amount_cents,
      credit_application_id: application_id
    })
    |> Repo.insert!()
  end

  # Remembers that a cash payment's funding participated in a transfer, so
  # its payment statement gains held_by_group.
  defp flag_transferred_fundings(draws) do
    funding_ids =
      draws
      |> Enum.map(fn {row, _take_cents} -> row.cash_funding_id end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Repo.update_all(
      from(f in CashFunding, where: f.id in ^funding_ids),
      set: [transferred: true]
    )

    :ok
  end

  ## start_finance_reporting

  # The first applied start operation enables reporting: the financial state
  # immediately before it — every operation already committed, in this batch
  # or earlier — becomes the opening position on starts_on. The operation
  # addresses no group and has no revision guard.
  defp start_finance_reporting(operation) do
    with {:ok, starts_on} <- reporting_date(operation),
         :ok <- ensure_reporting_not_started() do
      open_reporting(starts_on)

      applied(operation, %{starts_on: Date.to_string(starts_on)})
    else
      error -> rejection_for(operation, error)
    end
  end

  defp reporting_date(operation) do
    case parse_date(Map.get(operation, "starts_on")) do
      {:ok, starts_on} -> {:ok, starts_on}
      :error -> {:error, "invalid_reporting_date"}
    end
  end

  defp ensure_reporting_not_started do
    if reporting_state() do
      {:error, "reporting_already_started"}
    else
      :ok
    end
  end

  # Snapshots the opening position: held cash per property, the company-wide
  # credit liability, and every unexpired lot's remaining balance with its
  # expiry (so a later report can derive expiries that need no partner
  # operation). The watermark separates the already-committed operations —
  # their movements belong to the opening position — from later ones.
  defp open_reporting(starts_on) do
    watermark = Repo.one(from m in FundingMovement, select: max(m.id)) || 0

    state =
      %ReportingState{}
      |> ReportingState.changeset(%{
        starts_on: starts_on,
        movements_after_id: watermark,
        opening_credit_liability_cents: credit_liability(starts_on)
      })
      |> Repo.insert!()

    cash_openings =
      Repo.all(
        from rf in RoomFunding,
          join: r in Room,
          on: rf.room_id == r.id,
          join: g in Group,
          on: r.group_id == g.id,
          where: rf.kind == "cash" and rf.status == "held" and g.status == "active",
          group_by: g.property_id,
          select: %{
            reporting_state_id: ^state.id,
            property_id: g.property_id,
            held_cents: sum(rf.amount_cents)
          }
      )
      |> Enum.map(&Map.merge(&1, timestamps()))

    Repo.insert_all("reporting_cash_openings", cash_openings)

    lot_openings =
      CreditLot
      |> where([l], l.expires_on >= ^starts_on)
      |> Repo.all()
      |> Enum.map(fn lot ->
        Map.merge(
          %{
            reporting_state_id: state.id,
            credit_lot_id: lot.id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          },
          timestamps()
        )
      end)

    Repo.insert_all("reporting_lot_openings", lot_openings)

    :ok
  end

  defp timestamps do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    %{inserted_at: now}
  end

  ## Daily finance report

  @doc """
  Builds the finance report for one date: how held cash moved per property
  and how the company-wide hotel-credit liability moved, against the opening
  position captured when reporting started. Returns `:not_started` before
  reporting has started and `:before_start` for a date before `starts_on`.
  Reading a report never changes a report or any domain state.
  """
  def daily_report(date) do
    case reporting_state() do
      nil ->
        :not_started

      %ReportingState{} = state ->
        if Date.compare(date, state.starts_on) == :lt do
          :before_start
        else
          {:ok, build_daily_report(state, date)}
        end
    end
  end

  defp build_daily_report(state, date) do
    movements =
      Repo.all(
        from m in FundingMovement,
          where: m.id > ^state.movements_after_id and m.posting_on <= ^date,
          order_by: [asc: m.id]
      )

    %{
      date: Date.to_string(date),
      status: "open",
      cash: cash_report(state, movements, date),
      credit: credit_report(state, movements, date)
    }
  end

  ## Daily report: cash per property

  # {field, classification, sign}: how each named cash movement changes the
  # property's held cash.
  @cash_movements [
    {:received_cents, "received", 1},
    {:transferred_in_cents, "transferred_in", 1},
    {:transferred_out_cents, "transferred_out", -1},
    {:refunded_cents, "refunded", -1},
    {:retained_cents, "retained", -1},
    {:converted_to_credit_cents, "converted_to_credit", -1},
    {:reduced_cents, "reduced", -1},
    {:charged_back_cents, "charged_back", -1}
  ]

  @cash_signs Map.new(@cash_movements, fn {_field, classification, sign} ->
                {classification, sign}
              end)

  defp cash_report(state, movements, date) do
    openings =
      Repo.all(
        from o in "reporting_cash_openings",
          where: o.reporting_state_id == ^state.id,
          select: {o.property_id, o.held_cents}
      )
      |> Map.new()

    entries = cash_entries(movements)

    # Per property: the signed net of movements before the report date, and
    # the report date's own gross movements by classification.
    by_property =
      Enum.reduce(entries, %{}, fn {property_id, classification, cents, posting_on}, acc ->
        {before_cents, day} = Map.get(acc, property_id, {0, %{}})

        before_cents =
          if Date.compare(posting_on, date) == :lt do
            before_cents + cents * Map.fetch!(@cash_signs, classification)
          else
            before_cents
          end

        day =
          if posting_on == date do
            Map.update(day, classification, cents, &(&1 + cents))
          else
            day
          end

        Map.put(acc, property_id, {before_cents, day})
      end)

    (Map.keys(openings) ++ Map.keys(by_property))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      {before_cents, day} = Map.get(by_property, property_id, {0, %{}})
      opening_cents = Map.get(openings, property_id, 0) + before_cents

      day_net_cents =
        Enum.sum(
          for {classification, cents} <- day, do: cents * Map.fetch!(@cash_signs, classification)
        )

      %{
        property_id: property_id,
        opening_held_cents: opening_cents,
        movements:
          Map.new(@cash_movements, fn {field, classification, _sign} ->
            {field, Map.get(day, classification, 0)}
          end),
        closing_held_cents: opening_cents + day_net_cents
      }
    end)
    |> Enum.filter(fn entry ->
      entry.opening_held_cents != 0 or entry.closing_held_cents != 0 or
        Enum.any?(entry.movements, fn {_field, cents} -> cents != 0 end)
    end)
  end

  # Normalizes the cash movements into {property_id, classification, cents,
  # posting_on} entries, splitting transfers into their out and in sides.
  defp cash_entries(movements) do
    Enum.flat_map(movements, fn
      %FundingMovement{side: "cash", classification: "transferred"} = movement ->
        cents = movement.detail["cash_cents"] || movement.amount_cents

        [
          {movement.property_id, "transferred_out", cents, movement.posting_on},
          {movement.detail["destination_property_id"], "transferred_in", cents,
           movement.posting_on}
        ]

      %FundingMovement{side: "cash"} = movement ->
        [
          {movement.property_id, movement.classification, movement.amount_cents,
           movement.posting_on}
        ]

      %FundingMovement{side: "credit"} ->
        []
    end)
  end

  ## Daily report: company-wide credit

  # {field, classification, sign}: how each named credit movement changes the
  # company-wide credit liability.
  @credit_movements [
    {:issued_cents, "issued", 1},
    {:expired_cents, "expired", -1},
    {:consumed_cents, "consumed", -1},
    {:revoked_cents, "revoked", -1},
    {:absorbed_cents, "absorbed", -1}
  ]

  defp credit_report(state, movements, date) do
    events =
      for %FundingMovement{side: "credit", classification: classification} = movement <-
            movements,
          classification in ~w(issued expired consumed revoked absorbed) do
        movement
      end

    expired_by_date = expiries_by_date(state, movements, date)

    before_cents =
      Enum.sum(
        for movement <- events, Date.compare(movement.posting_on, date) == :lt do
          movement.amount_cents * credit_sign(movement.classification)
        end
      ) - derived_expired_before(expired_by_date, date)

    day_sums =
      Map.new(@credit_movements, fn {field, classification, _sign} ->
        cents =
          Enum.sum(
            for movement <- events,
                movement.classification == classification and movement.posting_on == date,
                do: movement.amount_cents
          )

        cents =
          if classification == "expired",
            do: cents + Map.get(expired_by_date, date, 0),
            else: cents

        {field, cents}
      end)

    day_net_cents =
      Enum.sum(
        for {field, _classification, sign} <- @credit_movements,
            do: Map.fetch!(day_sums, field) * sign
      )

    opening_cents = state.opening_credit_liability_cents + before_cents

    %{
      opening_liability_cents: opening_cents,
      movements: day_sums,
      closing_liability_cents: opening_cents + day_net_cents
    }
  end

  defp credit_sign("issued"), do: 1
  defp credit_sign(_classification), do: -1

  defp derived_expired_before(expired_by_date, date) do
    Enum.sum(
      for {expired_on, cents} <- expired_by_date,
          Date.compare(expired_on, date) == :lt,
          do: cents
    )
  end

  # Credit that remains unused through its expires_on date expires on the
  # following date, even when no partner operation was submitted that day.
  # Derives each lot's remaining balance on its expiry date from the opening
  # snapshot and the recorded credit events, grouped by the date the expiry
  # is reported. (Credit restored to an already-expired lot expires on the
  # restoring operation's own date and is a recorded expired movement, not a
  # derived one.)
  defp expiries_by_date(state, movements, date) do
    lot_openings =
      Repo.all(
        from o in "reporting_lot_openings",
          where: o.reporting_state_id == ^state.id,
          select: {o.credit_lot_id, {o.remaining_cents, o.expires_on}}
      )
      # Schemaless reads return date columns as ISO strings.
      |> Map.new(fn {lot_id, {remaining_cents, expires_on}} ->
        {lot_id, {remaining_cents, parse_iso_date(expires_on)}}
      end)

    # Lots issued after the start join the universe from their issued event.
    lot_expiries =
      Enum.reduce(movements, lot_openings, fn
        %FundingMovement{classification: "issued", detail: detail}, acc ->
          Map.put_new(acc, detail["lot_id"], {0, parse_iso_date(detail["expires_on"])})

        _movement, acc ->
          acc
      end)

    # Per lot, the events that change its remaining balance, in commit order.
    lot_deltas =
      for %FundingMovement{side: "credit", classification: classification} = movement <-
            movements,
          classification in ~w(issued applied_credit restored_credit revoked),
          lot_id = movement.detail["lot_id"],
          not is_nil(lot_id) do
        sign =
          case classification do
            "issued" -> 1
            "restored_credit" -> 1
            "applied_credit" -> -1
            "revoked" -> -1
          end

        {lot_id, movement.posting_on, movement.amount_cents * sign}
      end
      |> Enum.group_by(
        fn {lot_id, _posting_on, _delta} -> lot_id end,
        fn {_lot_id, posting_on, delta} -> {posting_on, delta} end
      )

    for {lot_id, {opening_cents, expires_on}} <- lot_expiries,
        not is_nil(expires_on),
        expiry_report_date = Date.add(expires_on, 1),
        Date.compare(expiry_report_date, state.starts_on) == :gt,
        Date.compare(expiry_report_date, date) != :gt,
        reduce: %{} do
      acc ->
        remaining_cents =
          opening_cents +
            Enum.sum(
              for {posting_on, delta} <- Map.get(lot_deltas, lot_id, []),
                  Date.compare(posting_on, expires_on) != :gt,
                  do: delta
            )

        if remaining_cents > 0 do
          add_cents(acc, expiry_report_date, remaining_cents)
        else
          acc
        end
    end
  end

  defp parse_iso_date(%Date{} = date), do: date

  defp parse_iso_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_iso_date(_value), do: nil

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

  # Transfer operations address their groups by named identifiers rather
  # than group_id; failures carry that group's own identifier.
  defp fetch_named_group(operation, key) do
    case Map.get(operation, key) do
      group_id when is_binary(group_id) ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> {:error, "group_not_found", %{group_id: group_id}}
          %Group{} = group -> {:ok, group}
        end

      _other ->
        {:error, "invalid_operation"}
    end
  end

  defp check_named_revision(operation, key, group) do
    case Map.get(operation, key) do
      nil ->
        :ok

      expected_revision ->
        if expected_revision == group.revision do
          :ok
        else
          {:error, "stale_revision",
           %{
             group_id: group.group_id,
             expected_revision: expected_revision,
             actual_revision: group.revision
           }}
        end
    end
  end

  defp ensure_transferable(source, destination) do
    if source.id != destination.id and source.guest_id == destination.guest_id do
      :ok
    else
      {:error, "invalid_transfer"}
    end
  end

  defp ensure_active_named(%Group{status: "active"}), do: :ok

  defp ensure_active_named(%Group{} = group),
    do: {:error, "group_not_active", %{group_id: group.group_id}}

  defp ensure_within_held_funding(group, amount_cents) do
    if amount_cents <= group.cash_paid_cents + group.credit_paid_cents do
      :ok
    else
      {:error, "transfer_exceeds_held_funding"}
    end
  end

  defp ensure_transfer_outstanding(group, amount_cents) do
    if amount_cents <= group.deposit_due_cents - group.deposit_paid_cents do
      :ok
    else
      {:error, "transfer_exceeds_outstanding"}
    end
  end

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

  ## Funding movements

  # Records one movement of an applied operation. Movements are domain
  # history: they are recorded whether or not reporting has started, so the
  # first start_finance_reporting operation can place every already-committed
  # operation into its opening position, and a durable retry reuses these
  # rows instead of reporting the movement twice. The reporting posting date
  # is the later of the operation's occurred_on and the reporting start date.
  defp record_movement(operation, occurred_on, side, classification, amount_cents, opts \\ []) do
    %FundingMovement{}
    |> FundingMovement.changeset(%{
      operation_id: Map.get(operation, "operation_id"),
      occurred_on: occurred_on,
      posting_on: posting_date(occurred_on),
      side: side,
      classification: classification,
      property_id: Keyword.get(opts, :property_id),
      amount_cents: amount_cents,
      detail: Keyword.get(opts, :detail, %{})
    })
    |> Repo.insert!()
  end

  # The operation's occurred_on date as used for movement recording.
  # Operations that validate occurred_on pass the parsed date directly; the
  # rest fall back to parsing it here.
  defp movement_date(operation) do
    case parse_date(Map.get(operation, "occurred_on")) do
      {:ok, occurred_on} -> occurred_on
      :error -> Date.utc_today()
    end
  end

  defp posting_date(occurred_on) do
    case reporting_state() do
      nil -> occurred_on
      %ReportingState{starts_on: starts_on} -> later_date(occurred_on, starts_on)
    end
  end

  defp later_date(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  defp reporting_state do
    Repo.one(from s in ReportingState, order_by: [asc: s.id], limit: 1)
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
