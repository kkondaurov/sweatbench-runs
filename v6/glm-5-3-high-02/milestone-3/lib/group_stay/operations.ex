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
  alias GroupStay.PartnerOperations
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit)
  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @refund_methods ~w(cash hotel_credit)
  @credit_bonus_percent 10
  @credit_validity_days 365

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
  defp fetch_context("open_group", operation) do
    with {:ok, group_id} <- require_string(operation, "group_id"),
         {:ok, guest_id} <- require_string(operation, "guest_id"),
         {:ok, property_id} <- require_string(operation, "property_id") do
      {:ok, %{group_id: group_id, guest_id: guest_id, property_id: property_id}}
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
    with :ok <- ensure_group_new(context.group_id, operation_id),
         {:ok, arrival_on, departure_on} <- parse_stay(operation),
         {:ok, rooms} <- parse_rooms(operation),
         {:ok, rate_plan} <- parse_rate_plan(operation),
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
         {:ok, _payment} <- Groups.create_payment(group, amount_cents, occurred_on),
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
           settle_cancellation(group, occurred_on, refund_method, operation, operation_id) do
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
         {:ok, _applications} <- Credit.consume_for_group(group, amount_cents, occurred_on),
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

    room_amounts = Enum.map(rooms, fn {_room_id, rate} -> nights * rate end)
    lodging_total_cents = Enum.sum(room_amounts)

    deposit_due_cents =
      case rate_plan do
        "flexible" -> Enum.sum(Enum.map(room_amounts, &flexible_deposit_cents/1))
        "advance_purchase" -> lodging_total_cents
      end

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

    room_attrs =
      Enum.map(rooms, fn {room_id, rate} -> %{room_id: room_id, nightly_rate_cents: rate} end)

    Groups.create_group(attrs, room_attrs)
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

  # -- cancel_group -------------------------------------------------------------

  defp parse_refund_method(%{"refund_method" => method}) when method in @refund_methods,
    do: {:ok, method}

  defp parse_refund_method(%{"refund_method" => nil}), do: {:ok, "cash"}
  defp parse_refund_method(%{"refund_method" => _other}), do: {:error, :invalid_operation}
  defp parse_refund_method(_operation), do: {:ok, "cash"}

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

  defp settle_cancellation(group, occurred_on, refund_method, operation, operation_id) do
    refundable = refundable?(group, occurred_on)
    cash_cents = Groups.held_paid_cents(group)

    payment_state =
      cond do
        refundable and refund_method == "hotel_credit" -> "converted"
        refundable -> "refunded"
        true -> "retained"
      end

    credit_issued_cents =
      if refundable and refund_method == "hotel_credit",
        do: credit_lot_amount_cents(cash_cents),
        else: 0

    with {:ok, updated} <- cancel(group, payment_state, operation, operation_id),
         :ok <- settle_applied_credit(group, refundable),
         {:ok, _lot} <-
           issue_credit_lot(group, credit_issued_cents, occurred_on, operation_id) do
      {refunded_cents, retained_cents} =
        cond do
          not refundable -> {0, cash_cents}
          refund_method == "hotel_credit" -> {0, 0}
          true -> {cash_cents, 0}
        end

      {:ok, updated,
       %{
         refunded_cents: refunded_cents,
         retained_cents: retained_cents,
         credit_issued_cents: credit_issued_cents
       }}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, rejected(operation_id, code)}
    end
  end

  defp credit_lot_amount_cents(0), do: 0

  defp credit_lot_amount_cents(cash_cents) do
    # The 10% bonus uses the standard rounding rule: nearest cent, an exact
    # half-cent rounds upward.
    bonus_cents = div(cash_cents * @credit_bonus_percent + 50, 100)
    cash_cents + bonus_cents
  end

  defp settle_applied_credit(group, true), do: Credit.restore_group_applications(group.id)
  defp settle_applied_credit(group, false), do: Credit.consume_group_applications(group.id)

  defp issue_credit_lot(_group, 0, _occurred_on, _operation_id), do: {:ok, nil}

  defp issue_credit_lot(group, amount_cents, occurred_on, operation_id) do
    Credit.issue_lot(%{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      remaining_cents: amount_cents,
      # Available through the day 365 days after cancellation, expiring the
      # following day.
      expires_on: Date.add(occurred_on, @credit_validity_days + 1)
    })
    |> case do
      {:ok, lot} -> {:ok, lot}
      {:error, _changeset} -> {:error, :invalid_operation}
    end
  end

  defp cancel(group, payment_state, operation, operation_id) do
    case Groups.cancel_group(group, payment_state) do
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
