defmodule GroupStay.Operations do
  @moduledoc """
  Processing of partner batch operations.

  Operations are applied in array order, each inside its own database
  transaction. An `operation_id` identifies an operation durably: the
  first submission is processed normally and remembered together with its
  result; a later submission with the same identifier and equivalent
  content replays the stored result without reading or changing domain
  state, while different content is rejected with `operation_id_conflict`.

  A handled rejection leaves domain state unchanged but still commits its
  idempotency record, so a retry observes the original rejection even if
  the operation would by then be valid. An unexpected exception rolls
  back the whole operation — including its idempotency record — and
  propagates, aborting the HTTP request so the gateway may retry the
  batch.
  """

  alias GroupStay.Credit
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Payment
  alias GroupStay.PartnerOperations
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit cancel_rooms reduce_cash_payment charge_back_payment)
  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @refund_methods ~w(cash hotel_credit)

  @type operation_result :: %{String.t() => term()}

  @doc """
  Processes a whole partner batch, returning `{:ok, results}` with one
  result per operation, or `{:error, :invalid_batch}` when the payload does
  not carry an operations array.

  An unexpected exception propagates: earlier operations stay committed
  and the HTTP request aborts, so the gateway may retry the batch.
  """
  @spec process_batch(map()) :: {:ok, [operation_result()]} | {:error, :invalid_batch}
  def process_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def process_batch(_), do: {:error, :invalid_batch}

  @doc """
  The reconciliation statement of a durably recorded, applied cash payment:
  the current disposition of every cent it recorded.

  Returns `{:error, :operation_not_found}` when no durable record exists
  and `{:error, :payment_not_reconcilable}` when the record is not an
  applied cash payment.
  """
  @spec payment_reconciliation(String.t()) ::
          {:ok, %{String.t() => term()}}
          | {:error, :operation_not_found | :payment_not_reconcilable}
  def payment_reconciliation(payment_operation_id) do
    case PartnerOperations.fetch(payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      record ->
        if applied_cash_payment?(record) do
          {:ok, payment_statement(record)}
        else
          {:error, :payment_not_reconcilable}
        end
    end
  end

  defp process_operation(operation) when is_map(operation) do
    case usable_operation_id(operation) do
      nil ->
        rejected(operation["operation_id"], :invalid_operation)

      operation_id ->
        process_remembered(operation, operation_id)
    end
  end

  defp process_operation(_operation), do: rejected(nil, :invalid_operation)

  # Only an operation carrying a usable identifier can be remembered.
  defp usable_operation_id(%{"operation_id" => operation_id})
       when is_binary(operation_id) and operation_id != "",
       do: operation_id

  defp usable_operation_id(_operation), do: nil

  defp process_remembered(operation, operation_id) do
    run_attempt(operation, operation_id, PartnerOperations.canonical_json(operation))
  end

  defp run_attempt(operation, operation_id, payload) do
    case attempt(operation, operation_id, payload) do
      {:ok, result} -> result
    end
  rescue
    # A concurrent duplicate committed its own record between our lookup
    # and our insert, which rolled this transaction back entirely. Start
    # over: the committed record now settles the retry.
    e in Ecto.ConstraintError ->
      if duplicate_record?(e) do
        case attempt(operation, operation_id, payload) do
          {:ok, result} -> result
        end
      else
        reraise e, __STACKTRACE__
      end
  end

  defp duplicate_record?(%Ecto.ConstraintError{type: :unique, constraint: constraint}),
    do: constraint == "partner_operations_operation_id_index"

  defp attempt(operation, operation_id, payload) do
    Repo.transact(fn ->
      case PartnerOperations.fetch(operation_id) do
        nil ->
          result = execute(operation, operation_id)

          PartnerOperations.record!(%{
            operation_id: operation_id,
            type: submitted_type(operation),
            payload: payload,
            result: Jason.encode!(result)
          })

          {:ok, result}

        record ->
          {:ok, replay(record, payload, operation_id)}
      end
    end)
  end

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_operation), do: nil

  # A retry with equivalent content returns the stored result verbatim,
  # without reading or changing current domain state. Different content
  # conflicts and never replaces the original record.
  defp replay(record, payload, operation_id) do
    if record.payload == payload do
      PartnerOperations.stored_result(record)
    else
      rejected(operation_id, :operation_id_conflict)
    end
  end

  # Runs one operation inside the surrounding transaction, wrapped in a
  # savepoint: an applied result keeps its changes, while a handled
  # rejection undoes whatever the attempt changed before the idempotency
  # record is committed. An exception escapes both, rolling the whole
  # transaction back.
  defp execute(operation, operation_id) do
    Repo.query!("SAVEPOINT gs_operation")

    case validate_and_run(operation, operation_id) do
      {:ok, result} ->
        Repo.query!("RELEASE SAVEPOINT gs_operation")
        result

      {:error, rejection} ->
        Repo.query!("ROLLBACK TO SAVEPOINT gs_operation")
        Repo.query!("RELEASE SAVEPOINT gs_operation")
        rejection
    end
  end

  defp validate_and_run(operation, operation_id) do
    with {:ok, type} <- fetch_type(operation),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         {:ok, context} <- fetch_context(type, operation) do
      run(type, operation, operation_id, occurred_on, context)
    else
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  # -- structural validation --------------------------------------------------

  defp fetch_type(%{"type" => type}) when type in @operation_types, do: {:ok, type}
  defp fetch_type(_), do: {:error, :invalid_operation}

  defp fetch_occurred_on(%{"occurred_on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_operation}
    end
  end

  defp fetch_occurred_on(_), do: {:error, :invalid_operation}

  # The fields needed to identify the operation and the group it addresses.
  # Payment corrections address the group of the payment they target.
  defp fetch_context("open_group", operation) do
    with {:ok, group_id} <- require_string(operation, "group_id"),
         {:ok, guest_id} <- require_string(operation, "guest_id"),
         {:ok, property_id} <- require_string(operation, "property_id") do
      {:ok, %{group_id: group_id, guest_id: guest_id, property_id: property_id}}
    end
  end

  defp fetch_context(type, operation) when type in ~w(reduce_cash_payment charge_back_payment) do
    case require_string(operation, "payment_operation_id") do
      {:ok, payment_operation_id} -> {:ok, %{payment_operation_id: payment_operation_id}}
      {:error, code} -> {:error, code}
    end
  end

  defp fetch_context(_type, operation) do
    case require_string(operation, "group_id") do
      {:ok, group_id} -> {:ok, %{group_id: group_id}}
      {:error, code} -> {:error, code}
    end
  end

  defp require_string(operation, key) do
    case operation do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_operation}
    end
  end

  defp run("open_group", operation, operation_id, occurred_on, context) do
    with {:ok, arrival_on, departure_on} <- parse_stay(operation),
         {:ok, rooms} <- parse_rooms(operation),
         {:ok, rate_plan} <- parse_rate_plan(operation),
         :ok <- ensure_group_new(context.group_id, operation_id),
         {:ok, group} <-
           create_group(context, occurred_on, arrival_on, departure_on, rooms, rate_plan) do
      {:ok,
       applied(operation_id, %{
         "group_id" => group.group_id,
         "deposit_due_cents" => group.deposit_due_cents,
         "revision" => group.revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp run("record_cash_payment", operation, operation_id, occurred_on, %{group_id: group_id}) do
    with {:ok, group} <- fetch_group(group_id, operation_id),
         :ok <- check_revision(group, operation, operation_id),
         :ok <- ensure_active(group, operation_id),
         {:ok, amount_cents} <- parse_amount(operation),
         :ok <- ensure_within_outstanding(group, amount_cents, operation_id),
         {:ok, _payment} <- Groups.create_payment(group, amount_cents, occurred_on, operation_id),
         {:ok, revision} <- bump_revision(group, operation, operation_id) do
      {:ok,
       applied(operation_id, %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group) - amount_cents,
         "revision" => revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp run("reschedule_group", operation, operation_id, occurred_on, %{group_id: group_id}) do
    with {:ok, group} <- fetch_group(group_id, operation_id),
         :ok <- check_revision(group, operation, operation_id),
         :ok <- ensure_active(group, operation_id),
         {:ok, new_arrival_on} <- parse_new_arrival(operation, occurred_on),
         {:ok, updated} <- reschedule(group, new_arrival_on, operation, operation_id) do
      {:ok,
       applied(operation_id, %{
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(updated.arrival_on),
         "new_departure_on" => Date.to_iso8601(updated.departure_on),
         "policy_version" => Groups.policy_version(updated),
         "refundable_until" => Groups.refundable_until_iso(updated),
         "revision" => updated.revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp run("cancel_group", operation, operation_id, occurred_on, %{group_id: group_id}) do
    with {:ok, group} <- fetch_group(group_id, operation_id),
         :ok <- check_revision(group, operation, operation_id),
         :ok <- ensure_active(group, operation_id),
         {:ok, refund_method} <- parse_refund_method(operation),
         :ok <- ensure_refund_method_available(group, occurred_on, refund_method, operation_id),
         {:ok, updated, settlement} <-
           settle_and_commit(
             group,
             Groups.active_rooms(group),
             occurred_on,
             refund_method,
             operation,
             operation_id,
             true
           ) do
      {:ok,
       applied(operation_id, %{
         "group_id" => group.group_id,
         "refunded_cents" => settlement.refunded_cents,
         "retained_cents" => settlement.retained_cents,
         "credit_issued_cents" => settlement.credit_issued_cents,
         "revision" => updated.revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp run("apply_hotel_credit", operation, operation_id, occurred_on, %{group_id: group_id}) do
    with {:ok, group} <- fetch_group(group_id, operation_id),
         :ok <- check_revision(group, operation, operation_id),
         :ok <- ensure_active(group, operation_id),
         {:ok, amount_cents} <- parse_amount(operation),
         :ok <- ensure_within_outstanding(group, amount_cents, operation_id),
         :ok <- Credit.consume_for_group(group, amount_cents, occurred_on, operation_id),
         {:ok, revision} <- bump_revision(group, operation, operation_id) do
      {:ok,
       applied(operation_id, %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group) - amount_cents,
         "revision" => revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp run("cancel_rooms", operation, operation_id, occurred_on, %{group_id: group_id}) do
    with {:ok, group} <- fetch_group(group_id, operation_id),
         :ok <- check_revision(group, operation, operation_id),
         :ok <- ensure_active(group, operation_id),
         {:ok, rooms} <- parse_selected_rooms(group, operation, operation_id),
         {:ok, refund_method} <- parse_refund_method(operation),
         :ok <- ensure_refund_method_available(group, occurred_on, refund_method, operation_id),
         {:ok, updated, settlement} <-
           settle_and_commit(
             group,
             rooms,
             occurred_on,
             refund_method,
             operation,
             operation_id,
             false
           ) do
      {:ok,
       applied(operation_id, %{
         "group_id" => group.group_id,
         "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
         "refunded_cents" => settlement.refunded_cents,
         "retained_cents" => settlement.retained_cents,
         "credit_issued_cents" => settlement.credit_issued_cents,
         "revision" => updated.revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp run("reduce_cash_payment", operation, operation_id, _occurred_on, %{
         payment_operation_id: payment_operation_id
       }) do
    with {:ok, record} <- fetch_durable_operation(payment_operation_id, operation_id),
         :ok <- ensure_applied_cash_payment(record, operation_id, :payment_not_reducible),
         {:ok, payment, group} <-
           resolve_payment(record, operation_id, :payment_not_reducible),
         :ok <- check_revision(group, operation, operation_id),
         :ok <- ensure_held_cash(payment, operation_id),
         {:ok, amount_cents} <- parse_amount(operation),
         :ok <- ensure_within_held_cash(payment, amount_cents, operation_id),
         {:ok, updated} <- apply_reduction(payment, group, amount_cents, operation, operation_id) do
      {:ok,
       applied(operation_id, %{
         "payment_operation_id" => payment_operation_id,
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => current_outstanding(group.group_id),
         "revision" => updated.revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp run("charge_back_payment", operation, operation_id, _occurred_on, %{
         payment_operation_id: payment_operation_id
       }) do
    with {:ok, record} <- fetch_durable_operation(payment_operation_id, operation_id),
         :ok <- ensure_applied_cash_payment(record, operation_id, :payment_not_chargeable),
         {:ok, payment, group} <- resolve_payment(record, operation_id, :payment_not_chargeable),
         :ok <- check_revision(group, operation, operation_id),
         :ok <- ensure_chargeable(payment, operation_id),
         {:ok, charged_back_cents, updated} <-
           apply_charge_back(payment, group, operation, operation_id) do
      {:ok,
       applied(operation_id, %{
         "payment_operation_id" => payment_operation_id,
         "group_id" => group.group_id,
         "charged_back_cents" => charged_back_cents,
         "outstanding_deposit_cents" => current_outstanding(group.group_id),
         "revision" => updated.revision
       })}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  # -- open_group ------------------------------------------------------------

  defp ensure_group_new(group_id, operation_id) do
    if Groups.group_exists?(group_id) do
      {:error, rejected(operation_id, :group_already_exists)}
    else
      :ok
    end
  end

  defp parse_stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation, "arrival_on", :invalid_stay),
         {:ok, departure_on} <- parse_date(operation, "departure_on", :invalid_stay) do
      if Date.diff(departure_on, arrival_on) >= 1 do
        {:ok, arrival_on, departure_on}
      else
        {:error, :invalid_stay}
      end
    end
  end

  defp parse_rooms(operation) do
    case operation do
      %{"rooms" => rooms} when is_list(rooms) and rooms != [] ->
        parse_room_entries(rooms, [])

      _ ->
        {:error, :invalid_rooms}
    end
  end

  defp parse_room_entries([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_room_entries([entry | rest], acc) when is_map(entry) do
    with {:ok, room_id} <- require_room_string(entry, "room_id"),
         {:ok, nightly_rate_cents} <- parse_nightly_rate(entry) do
      if Enum.any?(acc, &match?({^room_id, _}, &1)) do
        {:error, :invalid_rooms}
      else
        parse_room_entries(rest, [{room_id, nightly_rate_cents} | acc])
      end
    end
  end

  defp parse_room_entries([_ | _], _acc), do: {:error, :invalid_rooms}

  defp require_room_string(entry, key) do
    case entry do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_rooms}
    end
  end

  defp parse_nightly_rate(%{"nightly_rate_cents" => cents})
       when is_integer(cents) and cents >= 0,
       do: {:ok, cents}

  defp parse_nightly_rate(_), do: {:error, :invalid_rooms}

  defp parse_rate_plan(%{"rate_plan" => rate_plan}) when rate_plan in @rate_plans,
    do: {:ok, rate_plan}

  defp parse_rate_plan(_), do: {:error, :invalid_rate_plan}

  defp create_group(context, occurred_on, arrival_on, departure_on, rooms, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    room_entries =
      Enum.map(rooms, fn {room_id, rate} ->
        lodging_cents = nights * rate

        deposit_due_cents =
          if rate_plan == "flexible",
            do: flexible_deposit_cents(lodging_cents),
            else: lodging_cents

        %{room_id: room_id, nightly_rate_cents: rate, deposit_due_cents: deposit_due_cents}
      end)

    lodging_total_cents = nights * Enum.sum(Enum.map(rooms, fn {_id, rate} -> rate end))
    deposit_due_cents = Enum.sum(Enum.map(room_entries, & &1.deposit_due_cents))

    attrs = %{
      group_id: context.group_id,
      guest_id: context.guest_id,
      property_id: context.property_id,
      booked_on: occurred_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: rate_plan,
      policy_version: Groups.policy_version_for(rate_plan, occurred_on),
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents
    }

    Groups.create_group(attrs, room_entries)
  end

  defp flexible_deposit_cents(room_amount_cents) do
    numerator = room_amount_cents * @flexible_deposit_percent

    # Round to the nearest cent; an exact half-cent rounds upward.
    div(numerator + 50, 100)
  end

  # -- record_cash_payment ------------------------------------------------------

  defp parse_amount(%{"amount_cents" => amount}) when is_integer(amount) and amount > 0,
    do: {:ok, amount}

  defp parse_amount(_), do: {:error, :invalid_amount}

  defp ensure_within_outstanding(group, amount_cents, operation_id) do
    if amount_cents <= Groups.outstanding_deposit_cents(group) do
      :ok
    else
      {:error, rejected(operation_id, :payment_exceeds_outstanding)}
    end
  end

  # -- reschedule_group ---------------------------------------------------------

  defp parse_new_arrival(operation, occurred_on) do
    with {:ok, new_arrival_on} <- parse_date(operation, "new_arrival_on", :invalid_stay) do
      if Date.compare(new_arrival_on, occurred_on) == :gt do
        {:ok, new_arrival_on}
      else
        {:error, :invalid_stay}
      end
    end
  end

  defp reschedule(group, new_arrival_on, operation, operation_id) do
    shift_days = Date.diff(new_arrival_on, group.arrival_on)
    new_departure_on = Date.add(group.departure_on, shift_days)

    case Groups.reschedule_group(group, new_arrival_on, new_departure_on) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, _changeset} ->
        {:error,
         stale_rejection(
           operation_id,
           group.group_id,
           operation,
           Groups.current_revision(group.group_id)
         )}
    end
  end

  # -- cancellations -------------------------------------------------------------

  defp parse_refund_method(%{"refund_method" => method}) when method in @refund_methods,
    do: {:ok, method}

  defp parse_refund_method(%{"refund_method" => nil}), do: {:ok, "cash"}
  defp parse_refund_method(%{"refund_method" => _other}), do: {:error, :invalid_operation}
  defp parse_refund_method(_operation), do: {:ok, "cash"}

  # All supplied room identifiers must identify distinct, active rooms in
  # the group; the rooms are returned in the group's original order.
  defp parse_selected_rooms(group, operation, operation_id) do
    case operation do
      %{"room_ids" => room_ids} when is_list(room_ids) ->
        active_ids = MapSet.new(Groups.active_rooms(group), & &1.room_id)

        if room_ids != [] and Enum.all?(room_ids, &is_binary/1) and
             length(Enum.uniq(room_ids)) == length(room_ids) and
             Enum.all?(room_ids, &MapSet.member?(active_ids, &1)) do
          selected = MapSet.new(room_ids)
          {:ok, Enum.filter(group.rooms, &MapSet.member?(selected, &1.room_id))}
        else
          {:error, rejected(operation_id, :invalid_rooms)}
        end

      _ ->
        {:error, :invalid_operation}
    end
  end

  # Hotel credit is not a way around a non-refundable policy.
  defp ensure_refund_method_available(group, occurred_on, "hotel_credit", operation_id) do
    if refundable?(group, occurred_on) do
      :ok
    else
      {:error, rejected(operation_id, :refund_method_not_available)}
    end
  end

  defp ensure_refund_method_available(_group, _occurred_on, "cash", _operation_id), do: :ok

  defp refundable?(%Group{} = group, occurred_on) do
    case Groups.cancellation_window(Groups.policy_version(group)) do
      nil -> false
      window -> Date.diff(group.arrival_on, occurred_on) >= window
    end
  end

  # Settles the given rooms — selected rooms for `cancel_rooms`, the
  # remaining active rooms for `cancel_group` — under the same date,
  # policy, refund method, bonus, and restoration rules as a full
  # cancellation, then cancels the rooms and commits the group's revision.
  defp settle_and_commit(
         group,
         rooms,
         occurred_on,
         refund_method,
         operation,
         operation_id,
         force_cancel
       ) do
    refundable = refundable?(group, occurred_on)
    room_ids = Enum.map(rooms, & &1.id)

    held_cash = Groups.held_cash_allocations(group.id, room_ids)
    held_credit = Groups.held_credit_allocations(group.id, room_ids)
    cash_cents = Enum.sum(Enum.map(held_cash, & &1.amount_cents))

    Credit.settle_allocations(held_credit, if(refundable, do: :restore, else: :consume))

    cash_state =
      cond do
        refundable and refund_method == "hotel_credit" -> "converted"
        refundable -> "refunded"
        true -> "retained"
      end

    # The bonus applies once to the rooms' combined cash, not per room.
    lot =
      if cash_state == "converted" and cash_cents > 0,
        do: Credit.issue_conversion_lot(group, held_cash, occurred_on, operation_id),
        else: nil

    Groups.settle_cash_allocations(held_cash, cash_state, lot && lot.id)

    {refunded_cents, retained_cents} =
      cond do
        not refundable -> {0, cash_cents}
        refund_method == "hotel_credit" -> {0, 0}
        true -> {cash_cents, 0}
      end

    {:ok, updated, remaining_active} = Groups.cancel_rooms(group, rooms)

    group_changes =
      if force_cancel or remaining_active == [], do: [status: "cancelled"], else: []

    case Groups.apply_revision(updated, group_changes) do
      {:ok, final} ->
        {:ok, final,
         %{
           refunded_cents: refunded_cents,
           retained_cents: retained_cents,
           credit_issued_cents: if(lot, do: lot.remaining_cents, else: 0)
         }}

      {:error, :stale} ->
        {:error,
         stale_rejection(
           operation_id,
           group.group_id,
           operation,
           Groups.current_revision(group.group_id)
         )}
    end
  end

  # -- payment corrections -----------------------------------------------------

  defp fetch_durable_operation(payment_operation_id, operation_id) do
    case PartnerOperations.fetch(payment_operation_id) do
      nil -> {:error, rejected(operation_id, :operation_not_found)}
      record -> {:ok, record}
    end
  end

  # Only a durably recorded, applied cash payment can be corrected; the
  # check also resolves the group a correction addresses.
  defp ensure_applied_cash_payment(record, operation_id, code) do
    if applied_cash_payment?(record) do
      :ok
    else
      {:error, rejected(operation_id, code)}
    end
  end

  defp applied_cash_payment?(record) do
    record.type == "record_cash_payment" and
      match?(%{"status" => "applied"}, record_result(record))
  end

  defp record_result(record), do: Jason.decode!(record.result)

  defp resolve_payment(record, operation_id, code) do
    payment = Groups.fetch_payment_by_operation_id(record.operation_id)

    case {payment, payment && Repo.get(Group, payment.group_id)} do
      {nil, _} ->
        {:error, rejected(operation_id, code)}

      {%Payment{} = payment, %Group{} = group} ->
        {:ok, payment, group}

      {_payment, nil} ->
        {:error, rejected(operation_id, code)}
    end
  end

  defp ensure_held_cash(payment, operation_id) do
    if held_cash_cents(payment.operation_id) > 0 do
      :ok
    else
      {:error, rejected(operation_id, :payment_not_reducible)}
    end
  end

  defp held_cash_cents(payment_operation_id) do
    Groups.payment_dispositions(payment_operation_id)["held"]
  end

  defp ensure_within_held_cash(payment, amount_cents, operation_id) do
    if amount_cents <= held_cash_cents(payment.operation_id) do
      :ok
    else
      {:error, rejected(operation_id, :reduction_exceeds_held_cash)}
    end
  end

  defp apply_reduction(payment, group, amount_cents, operation, operation_id) do
    Groups.held_cash_allocations_of_payment(payment.operation_id)
    |> Groups.reduce_held_cash(amount_cents)

    case Groups.apply_revision(group) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, :stale} ->
        {:error,
         stale_rejection(
           operation_id,
           group.group_id,
           operation,
           Groups.current_revision(group.group_id)
         )}
    end
  end

  defp ensure_chargeable(payment, operation_id) do
    dispositions = Groups.payment_dispositions(payment.operation_id)

    cond do
      dispositions["reduced"] >= payment.amount_cents ->
        {:error, rejected(operation_id, :payment_not_chargeable)}

      dispositions["charged_back"] > 0 ->
        {:error, rejected(operation_id, :payment_not_chargeable)}

      true ->
        :ok
    end
  end

  defp apply_charge_back(payment, group, operation, operation_id) do
    # Converted principal becomes charged-back cash and the entitlement it
    # created is revoked; refunded and retained portions are reclassified
    # without reversing the historical settlement.
    Credit.claw_back_entitlements(payment.operation_id)

    charged_back_cents = Groups.charge_back_cash(payment.operation_id)

    case Groups.apply_revision(group) do
      {:ok, updated} ->
        {:ok, charged_back_cents, updated}

      {:error, :stale} ->
        {:error,
         stale_rejection(
           operation_id,
           group.group_id,
           operation,
           Groups.current_revision(group.group_id)
         )}
    end
  end

  # -- reconciliation -----------------------------------------------------------

  defp payment_statement(record) do
    payment = Groups.fetch_payment_by_operation_id(record.operation_id)
    result = record_result(record)

    dispositions =
      if payment,
        do: Groups.payment_dispositions(payment.operation_id),
        else: %{"held" => result["amount_cents"]}

    %{
      "payment_operation_id" => record.operation_id,
      "original_group_id" => result["group_id"],
      "recorded_cents" => (payment && payment.amount_cents) || result["amount_cents"],
      "held_cents" => dispositions["held"] || 0,
      "refunded_cents" => dispositions["refunded"] || 0,
      "retained_cents" => dispositions["retained"] || 0,
      "converted_to_credit_cents" => dispositions["converted"] || 0,
      "reduced_cents" => dispositions["reduced"] || 0,
      "charged_back_cents" => dispositions["charged_back"] || 0
    }
  end

  # -- shared group checks --------------------------------------------------------

  defp fetch_group(group_id, operation_id) do
    case Groups.fetch_by_group_id(group_id) do
      nil -> {:error, rejected(operation_id, :group_not_found)}
      %Group{} = group -> {:ok, group}
    end
  end

  defp ensure_active(%Group{status: "active"}, _operation_id), do: :ok

  defp ensure_active(_group, operation_id),
    do: {:error, rejected(operation_id, :group_not_active)}

  defp check_revision(group, operation, operation_id) do
    case operation do
      %{"expected_revision" => expected} when is_integer(expected) ->
        if expected == group.revision do
          :ok
        else
          {:error, stale_rejection(operation_id, group.group_id, expected, group.revision)}
        end

      %{"expected_revision" => other} when other != nil ->
        {:error, rejected(operation_id, :invalid_operation)}

      _ ->
        :ok
    end
  end

  defp bump_revision(group, operation, operation_id) do
    case Groups.bump_revision(group) do
      {:ok, revision} ->
        {:ok, revision}

      {:error, :stale} ->
        {:error,
         stale_rejection(
           operation_id,
           group.group_id,
           operation,
           Groups.current_revision(group.group_id)
         )}
    end
  end

  defp current_outstanding(group_id) do
    case Groups.fetch_by_group_id(group_id) do
      nil -> 0
      group -> Groups.outstanding_deposit_cents(group)
    end
  end

  # -- result building ------------------------------------------------------------

  defp parse_date(operation, key, error) do
    case operation do
      %{^key => value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, error}
        end

      _ ->
        {:error, error}
    end
  end

  defp applied(operation_id, fields) do
    Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)
  end

  defp rejected(operation_id, code) when is_atom(code),
    do: %{"operation_id" => operation_id, "status" => "rejected", "code" => Atom.to_string(code)}

  defp stale_rejection(operation_id, group_id, expected_revision, actual_revision)
       when is_integer(expected_revision) do
    %{
      "operation_id" => operation_id,
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group_id,
      "expected_revision" => expected_revision,
      "actual_revision" => actual_revision
    }
  end

  defp stale_rejection(operation_id, group_id, operation, actual_revision) do
    case operation do
      %{"expected_revision" => expected} when is_integer(expected) ->
        stale_rejection(operation_id, group_id, expected, actual_revision)

      _ ->
        %{
          "operation_id" => operation_id,
          "status" => "rejected",
          "code" => "stale_revision",
          "group_id" => group_id,
          "expected_revision" => nil,
          "actual_revision" => actual_revision
        }
    end
  end
end
