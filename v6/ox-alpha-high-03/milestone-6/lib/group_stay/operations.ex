defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations to group bookings and finance records.

  Each operation is applied inside its own database transaction. A rejected
  operation leaves domain state exactly as it was before that operation began,
  but its durable idempotency record commits so retries receive the original
  result. Processing of the remaining batch continues.
  """

  import Ecto.Query

  alias GroupStay.Bookings
  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Policy
  alias GroupStay.Bookings.Room
  alias GroupStay.Finance
  alias GroupStay.Finance.Allocations
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.CreditLotContribution
  alias GroupStay.Finance.PaymentTransfer
  alias GroupStay.Finance.Reporting
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  @flexible_deposit_percent 20
  @credit_bonus_percent 110
  @credit_available_days 365
  @rate_plans ~w(flexible advance_purchase)
  @refund_methods ~w(cash hotel_credit)

  @open_group_required ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

  @max_apply_attempts 5

  @doc """
  Applies each operation in order and returns one result map per operation.

  Operations are idempotent by `operation_id`: the first occurrence is
  processed normally and its result, applied or rejected, is committed durably.
  A retry with an equivalent payload replays the stored result without touching
  domain state; a retry with a different payload under the same identifier is
  rejected with `operation_id_conflict`.
  """
  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Applies a single operation and returns its result map.

  The idempotency record and any domain changes commit in the same database
  transaction. Handled rejections leave domain state unchanged but still commit
  their record. An unexpected exception rolls back the whole transaction,
  including the idempotency record, and propagates to abort the request.
  """
  def apply_operation(operation) when is_map(operation) do
    apply_with_retry(operation, @max_apply_attempts)
  end

  def apply_operation(_operation), do: failure(%{}, :invalid_operation)

  defp apply_with_retry(_operation, 0), do: raise("could not apply operation idempotently")

  defp apply_with_retry(operation, attempts) do
    case Repo.transaction(fn -> run_tracked(operation) end) do
      {:ok, result} ->
        result

      {:error, :idempotency_race} ->
        # Another transaction committed first for this operation_id. Retry so
        # the committed record decides between replay and conflict.
        apply_with_retry(operation, attempts - 1)
    end
  end

  defp run_tracked(operation) do
    case tracked_submission(operation) do
      :untracked ->
        execute_untracked(operation)

      {operation_id, submission} ->
        case Repo.get_by(OperationRecord, operation_id: operation_id) do
          %OperationRecord{} = record ->
            if record.submission == submission do
              decode_result(record.result)
            else
              failure(operation, :operation_id_conflict)
            end

          nil ->
            case dispatch(operation) do
              {:ok, fields} -> finish(operation, submission, success(operation, fields))
              {:error, reason} -> finish(operation, submission, failure(operation, reason))
            end
        end
    end
  end

  defp tracked_submission(operation) do
    case operation["operation_id"] do
      operation_id when is_binary(operation_id) and operation_id != "" ->
        {operation_id, canonical_submission(operation)}

      _other ->
        :untracked
    end
  end

  defp execute_untracked(operation) do
    case dispatch(operation) do
      {:ok, fields} -> success(operation, fields)
      {:error, reason} -> failure(operation, reason)
    end
  end

  defp finish(operation, submission, result) do
    record = %OperationRecord{
      operation_id: operation["operation_id"],
      type: record_type(operation["type"]),
      submission: submission,
      result: Jason.encode!(result)
    }

    case Repo.insert(record) do
      {:ok, _record} ->
        result

      {:error, _changeset} ->
        Repo.rollback(:idempotency_race)
    end
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint == "operation_records_operation_id_index" do
        # Lost a race against a concurrent retry of the same operation_id;
        # undo this transaction's domain changes and let the caller replay.
        Repo.rollback(:idempotency_race)
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp record_type(type) when is_binary(type), do: type
  defp record_type(_type), do: nil

  @doc """
  The exact stored result for `operation_id`, or nil when no durable record exists.
  """
  def get_stored_result(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> decode_result(record.result)
    end
  end

  @doc """
  The current disposition of the cash recorded by one applied cash payment.

  Every amount reflects current state and reading never mutates anything.
  Returns `{:error, :operation_not_found}` when no durable record exists and
  `{:error, :payment_not_reconcilable}` when the record is not an applied cash
  payment.
  """
  def payment_statement(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      %OperationRecord{type: "record_cash_payment"} = record ->
        case decode_result(record.result) do
          %{"status" => "applied", "group_id" => group_id} ->
            {:ok, statement(payment_operation_id, group_id)}

          _other ->
            {:error, :payment_not_reconcilable}
        end

      %OperationRecord{} ->
        {:error, :payment_not_reconcilable}
    end
  end

  defp statement(payment_operation_id, group_id) do
    dispositions = Finance.payment_dispositions(payment_operation_id)
    recorded = dispositions |> Map.values() |> Enum.sum()

    statement = %{
      "payment_operation_id" => payment_operation_id,
      "original_group_id" => group_id,
      "recorded_cents" => recorded,
      "held_cents" => Map.get(dispositions, "held", 0),
      "refunded_cents" => Map.get(dispositions, "refunded", 0),
      "retained_cents" => Map.get(dispositions, "retained", 0),
      "converted_to_credit_cents" => Map.get(dispositions, "converted_to_credit", 0),
      "reduced_cents" => Map.get(dispositions, "reduced", 0),
      "charged_back_cents" => Map.get(dispositions, "charged_back", 0)
    }

    # Once any of a payment's funding has participated in a transfer its
    # statement evolves to report where the held cash currently sits. The
    # breakdown sums to `held_cents` and is ordered by group id.
    if participated_in_transfer?(payment_operation_id) do
      Map.put(statement, "held_by_group", Finance.held_cash_by_group(payment_operation_id))
    else
      statement
    end
  end

  defp participated_in_transfer?(payment_operation_id) do
    Repo.exists?(from t in PaymentTransfer, where: t.operation_id == ^payment_operation_id)
  end

  # Canonical serialization of a submitted operation. Object key order is not
  # significant; array order and values remain significant.
  defp canonical_submission(operation) do
    operation
    |> canonicalize()
    |> Jason.encode!()
  end

  defp canonicalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), canonicalize(nested)} end)
  end

  defp canonicalize(values) when is_list(values), do: Enum.map(values, &canonicalize/1)
  defp canonicalize(value), do: value

  defp decode_result(stored), do: Jason.decode!(stored)

  # -- Operation handlers --------------------------------------------------

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp dispatch(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)
  defp dispatch(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp dispatch(%{"type" => "cancel_rooms"} = operation), do: cancel_rooms(operation)

  defp dispatch(%{"type" => "reduce_cash_payment"} = operation),
    do: reduce_cash_payment(operation)

  defp dispatch(%{"type" => "charge_back_payment"} = operation),
    do: charge_back_payment(operation)

  defp dispatch(%{"type" => "transfer_deposit"} = operation),
    do: transfer_deposit(operation)

  defp dispatch(%{"type" => "start_finance_reporting"} = operation),
    do: start_finance_reporting(operation)

  defp dispatch(_operation), do: {:error, :invalid_operation}

  # Starts finance reporting. The operation addresses no group and carries no
  # revision guard; the financial state immediately before it is processed
  # becomes the opening position on `starts_on`.
  defp start_finance_reporting(operation) do
    with {:ok, starts_on} <- Reporting.parse_date(operation["starts_on"]),
         :ok <- ensure_reporting_not_started() do
      Reporting.start!(starts_on)

      {:ok, %{"starts_on" => Date.to_iso8601(starts_on)}}
    end
  end

  defp ensure_reporting_not_started do
    if Reporting.started?() do
      {:error, :reporting_already_started}
    else
      :ok
    end
  end

  defp log_report(nil, _entries), do: :ok
  defp log_report(posting_date, entries), do: Reporting.log(posting_date, entries)

  # The report posting date of an operation applied after reporting started:
  # the later of its occurred_on and the reporting start date. Nil before
  # reporting has started, which disables movement logging.
  defp posting_date(occurred_on) do
    case Reporting.starts_on() do
      nil ->
        nil

      starts_on ->
        if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
    end
  end

  defp open_group(operation) do
    with :ok <- require_fields(operation, @open_group_required),
         :ok <- reject_existing_group(operation["group_id"]),
         {:ok, booked_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], :invalid_stay),
         {:ok, departure_on} <- parse_date(operation["departure_on"], :invalid_stay),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)
      rate_plan = operation["rate_plan"]

      room_rows =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {{room_id, nightly_rate_cents}, position} ->
          lodging_amount_cents = nightly_rate_cents * nights

          %Room{
            position: position,
            room_id: room_id,
            nightly_rate_cents: nightly_rate_cents,
            lodging_amount_cents: lodging_amount_cents,
            deposit_cents: deposit_for(rate_plan, lodging_amount_cents)
          }
        end)

      lodging_total_cents = room_rows |> Enum.map(& &1.lodging_amount_cents) |> Enum.sum()

      deposit_due_cents = room_rows |> Enum.map(& &1.deposit_cents) |> Enum.sum()

      group = %Group{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        status: "active",
        rate_plan: rate_plan,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        rooms: room_rows
      }

      case insert_group(group) do
        {:ok, _group} ->
          {:ok,
           %{
             "group_id" => group.group_id,
             "deposit_due_cents" => deposit_due_cents,
             "revision" => 1
           }}

        {:error, :group_already_exists} ->
          {:error, :group_already_exists}
      end
    end
  end

  defp insert_group(group) do
    Repo.insert(group)
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint == "groups_group_id_index" do
        # Lost a race against another process opening the same group id.
        {:error, :group_already_exists}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp record_cash_payment(operation) do
    with :ok <- require_fields(operation, ~w(operation_id occurred_on group_id amount_cents)),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- parse_payment_amount(operation["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount_cents),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation) do
      operation_id = operation["operation_id"]

      Repo.insert!(%CashMovement{
        group_id: group.id,
        kind: "held",
        amount_cents: amount_cents,
        occurred_on: occurred_on,
        operation_id: operation_id
      })

      Allocations.allocate(group.id, [
        %{funding_type: "cash", source_operation_id: operation_id, amount_cents: amount_cents}
      ])

      group = update_group!(group, [])

      log_report(posting_date(occurred_on), [
        {"received_cents", group.property_id, amount_cents}
      ])

      {:ok,
       %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group),
         "revision" => group.revision
       }}
    end
  end

  defp reschedule_group(operation) do
    with :ok <- require_fields(operation, ~w(operation_id occurred_on group_id new_arrival_on)),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"], :invalid_stay),
         :ok <- ensure_after(occurred_on, new_arrival_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      group = update_group!(group, arrival_on: new_arrival_on, departure_on: new_departure_on)

      {:ok,
       %{
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "policy_version" => Policy.version_for(group),
         "refundable_until" => group |> Policy.refundable_until() |> maybe_date_to_iso8601(),
         "revision" => group.revision
       }}
    end
  end

  defp cancel_group(operation) do
    with :ok <- require_fields(operation, ~w(operation_id occurred_on group_id)),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, refund_method} <- parse_refund_method(operation),
         rooms = active_rooms(group),
         :ok <- ensure_refund_available(refund_method, group, occurred_on) do
      {refunded_cents, retained_cents, credit_issued_cents} =
        settle_rooms(
          group,
          operation["operation_id"],
          occurred_on,
          posting_date(occurred_on),
          refund_method,
          rooms
        )

      group = update_group!(group, status: "cancelled")

      {:ok,
       %{
         "group_id" => group.group_id,
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "credit_issued_cents" => credit_issued_cents,
         "revision" => group.revision
       }}
    end
  end

  defp cancel_rooms(operation) do
    with :ok <- require_fields(operation, ~w(operation_id occurred_on group_id room_ids)),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, refund_method} <- parse_refund_method(operation),
         {:ok, selected} <- select_active_rooms(group, operation["room_ids"]),
         :ok <- ensure_refund_available(refund_method, group, occurred_on) do
      {refunded_cents, retained_cents, credit_issued_cents} =
        settle_rooms(
          group,
          operation["operation_id"],
          occurred_on,
          posting_date(occurred_on),
          refund_method,
          selected
        )

      selected_ids = MapSet.new(selected, & &1.id)
      rooms_remain? = Enum.any?(active_rooms(group), &(not MapSet.member?(selected_ids, &1.id)))

      group = update_group!(group, if(rooms_remain?, do: [], else: [status: "cancelled"]))

      {:ok,
       %{
         "group_id" => group.group_id,
         "cancelled_room_ids" => Enum.map(selected, & &1.room_id),
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "credit_issued_cents" => credit_issued_cents,
         "revision" => group.revision
       }}
    end
  end

  defp select_active_rooms(group, room_ids) do
    if is_list(room_ids) and room_ids != [] and Enum.all?(room_ids, &is_binary/1) and
         Enum.uniq(room_ids) == room_ids do
      lookup = Map.new(active_rooms(group), &{&1.room_id, &1})

      if Enum.all?(room_ids, &Map.has_key?(lookup, &1)) do
        {:ok, room_ids |> Enum.map(&Map.fetch!(lookup, &1)) |> Enum.sort_by(& &1.position)}
      else
        {:error, :invalid_rooms}
      end
    else
      {:error, :invalid_rooms}
    end
  end

  # Settles the allocated cash and credit of the given rooms using the
  # cancellation date, policy, refund method, bonus, and restoration rules of a
  # full cancellation. The hotel-credit bonus is computed once over the
  # selected rooms' combined cash.
  defp settle_rooms(group, operation_id, occurred_on, posting_date, refund_method, rooms) do
    room_ids = Enum.map(rooms, & &1.id)
    refundable? = Policy.refundable?(group, occurred_on)

    destination =
      cond do
        refundable? and refund_method == "hotel_credit" -> "converted_to_credit"
        refundable? -> "refunded"
        true -> "retained"
      end

    cash_allocations = Allocations.take_cash_allocations(room_ids)
    total_cash = cash_allocations |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    Enum.each(cash_allocations, fn {source_operation_id, amount_cents} ->
      move_held_cash(group.id, source_operation_id, amount_cents, destination, occurred_on)
    end)

    credit_issued_cents =
      if destination == "converted_to_credit" and total_cash > 0 do
        issue_conversion_lot(group, operation_id, occurred_on, total_cash, cash_allocations)
      else
        0
      end

    credit_per_lot = Allocations.take_credit_allocations(room_ids)

    {absorbed_cents, expired_cents} =
      if refundable? do
        restore_applied_credit(credit_per_lot, occurred_on)
      else
        {0, 0}
      end

    report_entries =
      Enum.map(cash_allocations, fn {_source_operation_id, amount_cents} ->
        {"#{destination}_cents", group.property_id, amount_cents}
      end) ++
        credit_settlement_entries(
          destination,
          credit_issued_cents,
          credit_per_lot,
          refundable?,
          absorbed_cents,
          expired_cents
        )

    log_report(posting_date, report_entries)

    from(r in Room, where: r.id in ^room_ids)
    |> Repo.update_all(set: [status: "cancelled"])

    {
      if(destination == "refunded", do: total_cash, else: 0),
      if(destination == "retained", do: total_cash, else: 0),
      credit_issued_cents
    }
  end

  # Report movements for the credit side of a settlement: issued liability when
  # cash converts into a lot, absorption or immediate expiry when applied
  # credit returns to lots on a refundable settlement, and consumption when
  # non-refundable settlement spends it.
  defp credit_settlement_entries(
         destination,
         credit_issued_cents,
         credit_per_lot,
         refundable?,
         absorbed_cents,
         expired_cents
       )

  defp credit_settlement_entries(
         "converted_to_credit",
         credit_issued_cents,
         _credit_per_lot,
         _refundable?,
         absorbed_cents,
         expired_cents
       ) do
    [{"issued_cents", nil, credit_issued_cents}] ++
      restoration_entries(absorbed_cents, expired_cents)
  end

  defp credit_settlement_entries(
         _destination,
         0,
         _credit_per_lot,
         true,
         absorbed_cents,
         expired_cents
       ) do
    restoration_entries(absorbed_cents, expired_cents)
  end

  defp credit_settlement_entries(_destination, 0, credit_per_lot, false, 0, 0) do
    Enum.map(credit_per_lot, fn {_lot_id, amount_cents} ->
      {"consumed_cents", nil, amount_cents}
    end)
  end

  defp restoration_entries(0, 0), do: []

  defp restoration_entries(absorbed_cents, expired_cents) do
    [
      {"absorbed_cents", nil, absorbed_cents},
      {"expired_cents", nil, expired_cents}
    ]
  end

  defp apply_hotel_credit(operation) do
    with :ok <- require_fields(operation, ~w(operation_id occurred_on group_id amount_cents)),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, amount_cents} <- parse_payment_amount(operation["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount_cents),
         :ok <- ensure_credit_available(group.guest_id, occurred_on, amount_cents) do
      consumed_lots = consume_credit_lots(group.guest_id, occurred_on, amount_cents)

      allocations =
        Enum.map(consumed_lots, fn {credit_lot_id, take} ->
          %{
            funding_type: "credit",
            source_operation_id: operation["operation_id"],
            credit_lot_id: credit_lot_id,
            amount_cents: take
          }
        end)

      Allocations.allocate(group.id, allocations)

      group = update_group!(group, [])

      {:ok,
       %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group),
         "revision" => group.revision
       }}
    end
  end

  defp reduce_cash_payment(operation) do
    with :ok <-
           require_fields(
             operation,
             ~w(operation_id occurred_on payment_operation_id amount_cents)
           ),
         {:ok, record} <- fetch_payment_record(operation["payment_operation_id"]),
         :ok <- ensure_applied_cash_payment(record, :payment_not_reducible),
         {:ok, group} <- group_of_result(record),
         :ok <- check_expected_revision(group, operation),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, amount_cents} <- parse_payment_amount(operation["amount_cents"]) do
      payment_operation_id = operation["payment_operation_id"]
      held_cents = Allocations.held_cash_for_source(payment_operation_id)

      with :ok <- ensure_reduction_within_held(held_cents, amount_cents) do
        {:ok, released} = Allocations.release_held_cash(payment_operation_id, amount_cents)

        move_held_cash(group.id, payment_operation_id, amount_cents, "reduced", occurred_on)

        # A reduction changes the state of every group whose held allocations
        # it touches, not only the addressed original payment group.
        released_groups = released |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        bump_revisions(released_groups -- [group.id])

        # Held cash may span several groups after transfers; each removed
        # portion is reported at the property where it was held.
        properties = properties_for(released_groups)

        log_report(
          posting_date(occurred_on),
          Enum.map(released, fn {group_id, removed_cents} ->
            {"reduced_cents", Map.fetch!(properties, group_id), removed_cents}
          end)
        )

        group = update_group!(group, [])

        {:ok,
         %{
           "payment_operation_id" => payment_operation_id,
           "group_id" => group.group_id,
           "amount_cents" => amount_cents,
           "outstanding_deposit_cents" => outstanding_deposit(group),
           "revision" => group.revision
         }}
      end
    end
  end

  defp charge_back_payment(operation) do
    with :ok <- require_fields(operation, ~w(operation_id occurred_on payment_operation_id)),
         {:ok, record} <- fetch_payment_record(operation["payment_operation_id"]),
         :ok <- ensure_applied_cash_payment(record, :payment_not_chargeable),
         {:ok, group} <- group_of_result(record),
         :ok <- check_expected_revision(group, operation),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         dispositions = Finance.payment_dispositions(operation["payment_operation_id"]),
         :ok <- ensure_chargeable_payment(dispositions) do
      payment_operation_id = operation["payment_operation_id"]

      held_cents = Allocations.held_cash_for_source(payment_operation_id)
      {:ok, released} = Allocations.release_held_cash(payment_operation_id, held_cents)

      released_groups = released |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      bump_revisions(released_groups -- [group.id])

      # Capture where settled cash sits before its movements are reclassified
      # to charged back in place.
      settled_by_property = settled_dispositions_by_property(payment_operation_id)

      charged_back_cents =
        disposition(dispositions, "held") + disposition(dispositions, "refunded") +
          disposition(dispositions, "retained") + disposition(dispositions, "converted_to_credit")

      reclassify_to_charged_back(payment_operation_id)
      revoked_cents = claw_back_entitlements(payment_operation_id)

      # Settled dispositions already carry the property where the cash was
      # settled; only held allocations need a group-to-property lookup.
      properties = properties_for(released_groups)

      held_entries =
        Enum.map(released, fn {group_id, removed_cents} ->
          {"charged_back_cents", Map.fetch!(properties, group_id), removed_cents}
        end)

      settled_entries =
        Enum.flat_map(settled_by_property, fn {kind, property_id, amount_cents} ->
          [
            {"#{kind}_cents", property_id, -amount_cents},
            {"charged_back_cents", property_id, amount_cents}
          ]
        end)

      log_report(
        posting_date(occurred_on),
        held_entries ++ settled_entries ++ [{"revoked_cents", nil, revoked_cents}]
      )

      group = update_group!(group, [])

      {:ok,
       %{
         "payment_operation_id" => payment_operation_id,
         "group_id" => group.group_id,
         "charged_back_cents" => charged_back_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group),
         "revision" => group.revision
       }}
    end
  end

  # Moves held funding (cash and hotel credit alike) between two active groups
  # of the same guest. Units are drawn from the source's active rooms in
  # reverse allocation order and placed onto the destination's active rooms in
  # their original order, keeping each unit's provenance. Nothing settles,
  # revalues, or expires; no ledger total changes.
  defp transfer_deposit(operation) do
    with :ok <-
           require_fields(
             operation,
             ~w(operation_id occurred_on source_group_id destination_group_id amount_cents)
           ),
         {:ok, source} <- fetch_transfer_group(operation["source_group_id"]),
         {:ok, destination} <- fetch_transfer_group(operation["destination_group_id"]),
         :ok <- check_expected_revision(source, operation),
         :ok <- check_expected_revision(destination, operation, "destination_expected_revision"),
         :ok <- ensure_distinct_same_guest(source, destination),
         :ok <- ensure_transfer_active(source),
         :ok <- ensure_transfer_active(destination),
         {:ok, amount_cents} <- parse_payment_amount(operation["amount_cents"]),
         :ok <- ensure_within_held_funding(source, amount_cents),
         :ok <- ensure_transfer_within_outstanding(destination, amount_cents),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation) do
      units = Allocations.take_funding_reverse(source.id, amount_cents)

      Allocations.allocate(
        destination.id,
        Enum.map(
          units,
          &Map.take(&1, [:funding_type, :source_operation_id, :credit_lot_id, :amount_cents])
        )
      )

      # Credit has no property dimension; only the cash portion of the moved
      # funding appears as transferred-out/in on the two groups' properties.
      cash_moved_cents =
        units
        |> Enum.filter(&(&1.funding_type == "cash"))
        |> Enum.map(& &1.amount_cents)
        |> Enum.sum()

      log_report(posting_date(occurred_on), [
        {"transferred_out_cents", source.property_id, cash_moved_cents},
        {"transferred_in_cents", destination.property_id, cash_moved_cents}
      ])

      units
      |> Enum.filter(&(&1.funding_type == "cash"))
      |> Enum.group_by(& &1.source_operation_id, & &1.amount_cents)
      |> Enum.each(fn {source_operation_id, amounts} ->
        move_held_funding_between_groups(
          source_operation_id,
          Enum.sum(amounts),
          source.id,
          destination.id
        )

        mark_payment_transferred(source_operation_id)
      end)

      source = update_group!(source, [])
      destination = update_group!(destination, [])

      {:ok,
       %{
         "source_group_id" => source.group_id,
         "destination_group_id" => destination.group_id,
         "amount_cents" => amount_cents,
         "source_outstanding_deposit_cents" => outstanding_deposit(source),
         "destination_outstanding_deposit_cents" => outstanding_deposit(destination),
         "source_revision" => source.revision,
         "destination_revision" => destination.revision
       }}
    end
  end

  defp ensure_distinct_same_guest(%Group{id: id}, %Group{id: id}), do: {:error, :invalid_transfer}

  defp ensure_distinct_same_guest(source, destination) do
    if source.guest_id == destination.guest_id do
      :ok
    else
      {:error, :invalid_transfer}
    end
  end

  # A missing group in a transfer is reported with the identifier the partner
  # supplied for it.
  defp fetch_transfer_group(group_id) do
    case Bookings.get_group(group_id) do
      nil -> {:error, {:group_not_found, group_id}}
      group -> {:ok, group}
    end
  end

  defp ensure_transfer_active(%Group{status: "active"}), do: :ok
  defp ensure_transfer_active(group), do: {:error, {:group_not_active, group.group_id}}

  defp ensure_within_held_funding(source, amount_cents) do
    if amount_cents <= Allocations.held_funding(source.id) do
      :ok
    else
      {:error, :transfer_exceeds_held_funding}
    end
  end

  defp ensure_transfer_within_outstanding(destination, amount_cents) do
    if amount_cents <= outstanding_deposit(destination) do
      :ok
    else
      {:error, :transfer_exceeds_outstanding}
    end
  end

  # Records that a cash payment has participated in a transfer so its statement
  # reports the `held_by_group` breakdown from now on.
  defp mark_payment_transferred(nil), do: :ok

  defp mark_payment_transferred(payment_operation_id) do
    Repo.insert!(
      %PaymentTransfer{operation_id: payment_operation_id},
      on_conflict: :nothing,
      conflict_target: :operation_id
    )

    :ok
  end

  # -- Result builders -------------------------------------------------------

  defp success(operation, fields) do
    Map.merge(%{"operation_id" => operation["operation_id"], "status" => "applied"}, fields)
  end

  defp failure(operation, {:stale_revision, group_id, expected, actual}) do
    %{
      "operation_id" => operation["operation_id"],
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group_id,
      "expected_revision" => expected,
      "actual_revision" => actual
    }
  end

  defp failure(operation, {:group_not_active, group_id}) do
    %{
      "operation_id" => operation["operation_id"],
      "status" => "rejected",
      "code" => "group_not_active",
      "group_id" => group_id
    }
  end

  defp failure(operation, code) when is_atom(code) do
    %{
      "operation_id" => operation["operation_id"],
      "status" => "rejected",
      "code" => Atom.to_string(code)
    }
  end

  defp failure(operation, {:group_not_found, group_id}) do
    %{
      "operation_id" => operation["operation_id"],
      "status" => "rejected",
      "code" => "group_not_found",
      "group_id" => group_id
    }
  end

  # -- Shared validation steps -----------------------------------------------

  defp require_fields(operation, fields) do
    if Enum.all?(fields, fn field -> present?(Map.get(operation, field)) end) do
      :ok
    else
      {:error, :invalid_operation}
    end
  end

  defp present?(value), do: not (is_nil(value) or value == "")

  defp reject_existing_group(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:error, :group_already_exists}
    else
      :ok
    end
  end

  defp fetch_group(group_id) do
    case Bookings.get_group(group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp fetch_payment_record(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, record}
    end
  end

  defp ensure_applied_cash_payment(record, code) do
    if record.type == "record_cash_payment" and
         match?(%{"status" => "applied"}, decode_result(record.result)) do
      :ok
    else
      {:error, code}
    end
  end

  defp group_of_result(record) do
    decode_result(record.result)
    |> Map.fetch!("group_id")
    |> fetch_group()
  end

  defp ensure_reduction_within_held(0, _amount_cents), do: {:error, :payment_not_reducible}

  defp ensure_reduction_within_held(held_cents, amount_cents) do
    if amount_cents <= held_cents do
      :ok
    else
      {:error, :reduction_exceeds_held_cash}
    end
  end

  defp ensure_chargeable_payment(dispositions) do
    remaining =
      disposition(dispositions, "held") + disposition(dispositions, "refunded") +
        disposition(dispositions, "retained") + disposition(dispositions, "converted_to_credit")

    cond do
      disposition(dispositions, "charged_back") > 0 -> {:error, :payment_not_chargeable}
      remaining == 0 -> {:error, :payment_not_chargeable}
      true -> :ok
    end
  end

  defp disposition(dispositions, kind), do: Map.get(dispositions, kind, 0)

  defp check_expected_revision(group, operation, key \\ "expected_revision")

  defp check_expected_revision(group, operation, key) do
    case Map.get(operation, key) do
      nil ->
        :ok

      expected when expected == group.revision ->
        :ok

      expected ->
        {:error, {:stale_revision, group.group_id, expected, group.revision}}
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, :group_not_active}

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp parse_date(_value, code), do: {:error, code}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  defp ensure_after(occurred_on, date) do
    if Date.compare(date, occurred_on) == :gt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans do
      :ok
    else
      {:error, :invalid_rate_plan}
    end
  end

  defp validate_rooms(rooms) do
    if is_list(rooms) and rooms != [] do
      reduce_rooms(rooms, [], MapSet.new())
    else
      {:error, :invalid_rooms}
    end
  end

  defp reduce_rooms([room | rest], acc, seen_ids) do
    cond do
      not is_map(room) ->
        {:error, :invalid_rooms}

      not valid_room_id?(room["room_id"]) or not valid_rate_cents?(room["nightly_rate_cents"]) ->
        {:error, :invalid_rooms}

      MapSet.member?(seen_ids, room["room_id"]) ->
        {:error, :invalid_rooms}

      true ->
        reduce_rooms(
          rest,
          [{room["room_id"], room["nightly_rate_cents"]} | acc],
          MapSet.put(seen_ids, room["room_id"])
        )
    end
  end

  defp reduce_rooms([], acc, _seen_ids), do: {:ok, Enum.reverse(acc)}

  defp valid_room_id?(room_id), do: is_binary(room_id) and room_id != ""

  defp valid_rate_cents?(rate_cents), do: is_integer(rate_cents) and rate_cents > 0

  defp parse_payment_amount(amount_cents) do
    if is_integer(amount_cents) and amount_cents > 0 do
      {:ok, amount_cents}
    else
      {:error, :invalid_amount}
    end
  end

  defp ensure_within_outstanding(group, amount_cents) do
    if amount_cents <= outstanding_deposit(group) do
      :ok
    else
      {:error, :payment_exceeds_outstanding}
    end
  end

  defp outstanding_deposit(group) do
    Bookings.group_totals(group).outstanding_deposit_cents
  end

  defp active_rooms(group), do: Enum.filter(group.rooms, &Room.active?/1)

  # -- Hotel credit ------------------------------------------------------------

  defp parse_refund_method(operation) do
    case Map.get(operation, "refund_method") do
      nil ->
        {:ok, "cash"}

      refund_method when refund_method in @refund_methods ->
        {:ok, refund_method}

      _other ->
        {:error, :invalid_operation}
    end
  end

  defp ensure_refund_available(refund_method, group, occurred_on) do
    if refund_method == "hotel_credit" and not Policy.refundable?(group, occurred_on) do
      {:error, :refund_method_not_available}
    else
      :ok
    end
  end

  # Moves `amount_cents` of one funding source's currently-held cash to a new
  # disposition. Legacy funding (`nil` source) moves as one block within its
  # own group; identified payments may fund several groups after transfers, so
  # their held movements are consumed wherever they currently sit.
  defp move_held_cash(group_id, source_operation_id, amount_cents, new_kind, occurred_on) do
    from(m in CashMovement, where: m.kind == "held", order_by: m.id)
    |> scope_held_source(source_operation_id, group_id)
    |> Repo.all()
    |> Enum.reduce_while(amount_cents, fn movement, left ->
      take = min(movement.amount_cents, left)

      if take == movement.amount_cents do
        Repo.delete!(movement)
      else
        movement
        |> Ecto.Changeset.change(amount_cents: movement.amount_cents - take)
        |> Repo.update!()
      end

      case left - take do
        0 -> {:halt, 0}
        rest -> {:cont, rest}
      end
    end)
    |> case do
      0 ->
        Repo.insert!(%CashMovement{
          group_id: group_id,
          kind: new_kind,
          amount_cents: amount_cents,
          occurred_on: occurred_on,
          operation_id: source_operation_id
        })

      unplaced when unplaced > 0 ->
        raise("held cash movements are missing #{unplaced} cents for the requested source")
    end

    :ok
  end

  # Keeps the "held" kind but reattributes `amount_cents` of a source's held
  # cash from one group's rooms to another's. Whole movements follow the
  # destination; a partially consumed movement is trimmed and its remainder is
  # recorded on the destination with the original date.
  defp move_held_funding_between_groups(
         source_operation_id,
         amount_cents,
         source_group_id,
         destination_group_id
       ) do
    from(m in CashMovement, where: m.kind == "held", order_by: m.id)
    |> scope_held_source(source_operation_id, source_group_id)
    |> Repo.all()
    |> Enum.reduce_while(amount_cents, fn movement, left ->
      take = min(movement.amount_cents, left)

      if take == movement.amount_cents do
        movement
        |> Ecto.Changeset.change(group_id: destination_group_id)
        |> Repo.update!()
      else
        movement
        |> Ecto.Changeset.change(amount_cents: movement.amount_cents - take)
        |> Repo.update!()

        Repo.insert!(%CashMovement{
          group_id: destination_group_id,
          kind: "held",
          amount_cents: take,
          occurred_on: movement.occurred_on,
          operation_id: movement.operation_id
        })
      end

      case left - take do
        0 -> {:halt, 0}
        rest -> {:cont, rest}
      end
    end)
    |> case do
      0 ->
        :ok

      unplaced when unplaced > 0 ->
        raise("held cash movements are missing #{unplaced} cents for the requested source")
    end
  end

  defp scope_held_source(query, nil, group_id) do
    where(query, [m], m.group_id == ^group_id and is_nil(m.operation_id))
  end

  defp scope_held_source(query, source_operation_id, _group_id) do
    where(query, [m], m.operation_id == ^source_operation_id)
  end

  defp reclassify_to_charged_back(payment_operation_id) do
    from(m in CashMovement,
      where:
        m.operation_id == ^payment_operation_id and
          m.kind in ["held", "refunded", "retained", "converted_to_credit"]
    )
    |> Repo.update_all(set: [kind: "charged_back"])

    :ok
  end

  # Where a payment's already-settled cash (refunded, retained, or converted)
  # currently sits, grouped by disposition kind and property. A later chargeback
  # follows that cash back to the property where it was settled.
  defp settled_dispositions_by_property(payment_operation_id) do
    from(m in CashMovement,
      join: g in Group,
      on: g.id == m.group_id,
      where:
        m.operation_id == ^payment_operation_id and
          m.kind in ["refunded", "retained", "converted_to_credit"],
      group_by: [m.kind, g.property_id],
      select: {m.kind, g.property_id, coalesce(sum(m.amount_cents), 0)}
    )
    |> Repo.all()
  end

  defp properties_for(group_ids) do
    from(g in Group, where: g.id in ^group_ids, select: {g.id, g.property_id})
    |> Repo.all()
    |> Map.new()
  end

  # Issues the hotel-credit lot worth 110% of the converted cash and records
  # each contributing payment's telescoping entitlement in the funding order
  # used by room accounting, with the unattributed senior block first.
  defp issue_conversion_lot(group, operation_id, cancelled_on, total_cash, cash_allocations) do
    issued_cents = bonus_amount(total_cash)

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        original_amount_cents: issued_cents,
        remaining_cents: issued_cents,
        expires_on: Date.add(cancelled_on, @credit_available_days + 1)
      })

    cash_allocations
    |> contributors_in_funding_order()
    |> Enum.map_reduce(0, fn {source_operation_id, amount_cents}, running_total ->
      entitled_cents =
        bonus_amount(running_total + amount_cents) - bonus_amount(running_total)

      Repo.insert!(%CreditLotContribution{
        credit_lot_id: lot.id,
        payment_operation_id: source_operation_id,
        entitled_cents: entitled_cents
      })

      {entitled_cents, running_total + amount_cents}
    end)

    issued_cents
  end

  defp contributors_in_funding_order(cash_allocations) do
    {legacy, durable} = Enum.split_with(cash_allocations, fn {source, _} -> is_nil(source) end)

    commit_positions =
      durable
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> then(fn ids ->
        from(r in OperationRecord,
          where: r.operation_id in ^ids,
          select: {r.operation_id, r.id}
        )
        |> Repo.all()
        |> Map.new()
      end)

    durable_sorted =
      Enum.sort_by(durable, fn {source, _} -> Map.get(commit_positions, source) end)

    legacy ++ durable_sorted
  end

  defp ensure_credit_available(guest_id, as_of, amount_cents) do
    if Finance.available_credit(guest_id, as_of) >= amount_cents do
      :ok
    else
      {:error, :insufficient_credit}
    end
  end

  defp consume_credit_lots(guest_id, as_of, amount_cents) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.expires_on > ^as_of and l.remaining_cents > 0,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )

    Enum.reduce_while(lots, {amount_cents, []}, fn lot, {remaining_need, acc} ->
      take = min(lot.remaining_cents, remaining_need)

      from(l in CreditLot,
        where: l.id == ^lot.id,
        update: [inc: [remaining_cents: -(^take)]]
      )
      |> Repo.update_all([])

      case remaining_need - take do
        0 -> {:halt, {[{lot.id, take} | acc], 0}}
        left -> {:cont, {left, [{lot.id, take} | acc]}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Returns applied hotel credit to its original lots on a refundable
  # settlement. Lots whose expiry is already past expire immediately instead of
  # becoming available again. Returning credit extinguishes a lot's unrecovered
  # clawback before making any amount available, whatever the expiry.
  #
  # Returns `{absorbed_cents, expired_cents}`: the amounts that reduced credit
  # liability - clawback absorption and restorations into lots whose expiry has
  # already passed.
  defp restore_applied_credit(credit_per_lot, occurred_on) do
    Enum.reduce(credit_per_lot, {0, 0}, fn {credit_lot_id, amount_cents},
                                           {absorbed_total, expired_total} ->
      lot = Repo.get!(CreditLot, credit_lot_id)
      absorbed = min(amount_cents, lot.unrecovered_clawback_cents)
      restored = amount_cents - absorbed

      changes = %{unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed}

      {changes, expired} =
        if Date.compare(lot.expires_on, occurred_on) == :gt do
          {Map.put(changes, :remaining_cents, lot.remaining_cents + restored), 0}
        else
          # The lot's expiry is past: the restored amount reduces the credit
          # liability immediately instead of becoming available again.
          {changes, restored}
        end

      lot
      |> Ecto.Changeset.change(changes)
      |> Repo.update!()

      {absorbed_total + absorbed, expired_total + expired}
    end)
  end

  # Revokes every entitlement a payment earned inside issued credit lots. What
  # cannot be removed from a lot's remaining balance becomes that lot's
  # unrecovered clawback. Returns the total amount actually removed from
  # available credit, which is the revocation reported in finance reporting.
  defp claw_back_entitlements(payment_operation_id) do
    contributions =
      Repo.all(
        from c in CreditLotContribution,
          where: c.payment_operation_id == ^payment_operation_id
      )

    Enum.reduce(contributions, 0, fn contribution, revoked_total ->
      lot = Repo.get!(CreditLot, contribution.credit_lot_id)
      removed = min(contribution.entitled_cents, lot.remaining_cents)

      lot
      |> Ecto.Changeset.change(%{
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + (contribution.entitled_cents - removed)
      })
      |> Repo.update!()

      revoked_total + removed
    end)
  end

  defp maybe_date_to_iso8601(nil), do: nil
  defp maybe_date_to_iso8601(date), do: Date.to_iso8601(date)

  # -- Money -----------------------------------------------------------------

  @doc """
  The deposit required for one room's lodging amount.

  Flexible reservations require a percentage of the lodging amount; advance
  purchase requires the full amount. Percentages round to the nearest cent
  with an exact half-cent rounding upward.
  """
  def deposit_for("flexible", lodging_amount_cents) do
    round_percentage(lodging_amount_cents, @flexible_deposit_percent)
  end

  def deposit_for("advance_purchase", lodging_amount_cents), do: lodging_amount_cents

  defp round_percentage(amount_cents, percent) do
    div(amount_cents * percent + 50, 100)
  end

  defp bonus_amount(cash_cents), do: div(cash_cents * @credit_bonus_percent + 50, 100)

  # -- Persistence helpers ---------------------------------------------------

  defp update_group!(group, attrs) do
    group
    |> Ecto.Changeset.change(Map.new(attrs) |> Map.put(:revision, group.revision + 1))
    |> Repo.update!()
  end

  # Increments the revision of groups whose state an operation changed without
  # being the group the operation is addressed to.
  defp bump_revisions([]), do: :ok

  defp bump_revisions(group_ids) do
    from(g in Group, where: g.id in ^group_ids)
    |> Repo.update_all(inc: [revision: 1])

    :ok
  end
end
