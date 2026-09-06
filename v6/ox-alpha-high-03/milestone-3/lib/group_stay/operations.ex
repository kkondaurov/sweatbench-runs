defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations to group bookings and finance records.

  Each operation is applied inside its own database transaction. A rejected
  operation leaves domain state exactly as it was before that operation began,
  but its durable idempotency record commits so retries receive the original
  result. Processing of the remaining batch continues.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Policy
  alias GroupStay.Bookings.Room
  alias GroupStay.Finance
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.CreditApplication
  alias GroupStay.Finance.CreditLot
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

  defp dispatch(_operation), do: {:error, :invalid_operation}

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
      Repo.insert!(%CashMovement{
        group_id: group.id,
        kind: "held",
        amount_cents: amount_cents,
        occurred_on: occurred_on
      })

      group = update_group!(group, [])

      {:ok,
       %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group.id, group.deposit_due_cents),
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
         {:ok, refund_method} <- parse_refund_method(operation) do
      paid_cents = Finance.cash_held(group.id)
      refundable? = Policy.refundable?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable? do
        {:error, :refund_method_not_available}
      else
        settle_cancellation(
          group,
          operation["operation_id"],
          occurred_on,
          refund_method,
          paid_cents,
          refundable?
        )
      end
    end
  end

  defp settle_cancellation(group, operation_id, occurred_on, "hotel_credit", paid_cents, true) do
    convert_cash_movements(group.id, "converted_to_credit")
    credit_issued_cents = issue_credit_lot(group, operation_id, occurred_on, paid_cents)
    restore_applied_credit(group, occurred_on)

    group = update_group!(group, status: "cancelled")

    {:ok,
     %{
       "group_id" => group.group_id,
       "refunded_cents" => 0,
       "retained_cents" => 0,
       "credit_issued_cents" => credit_issued_cents,
       "revision" => group.revision
     }}
  end

  defp settle_cancellation(group, _operation_id, occurred_on, _refund_method, paid_cents, true) do
    convert_cash_movements(group.id, "refunded")
    restore_applied_credit(group, occurred_on)

    group = update_group!(group, status: "cancelled")

    {:ok,
     %{
       "group_id" => group.group_id,
       "refunded_cents" => paid_cents,
       "retained_cents" => 0,
       "credit_issued_cents" => 0,
       "revision" => group.revision
     }}
  end

  defp settle_cancellation(group, _operation_id, _occurred_on, _refund_method, paid_cents, false) do
    convert_cash_movements(group.id, "retained")
    consume_applied_credit(group)

    group = update_group!(group, status: "cancelled")

    {:ok,
     %{
       "group_id" => group.group_id,
       "refunded_cents" => 0,
       "retained_cents" => paid_cents,
       "credit_issued_cents" => 0,
       "revision" => group.revision
     }}
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
      consume_credit_lots(group.id, group.guest_id, occurred_on, amount_cents)

      group = update_group!(group, [])

      {:ok,
       %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group.id, group.deposit_due_cents),
         "revision" => group.revision
       }}
    end
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

  defp failure(operation, code) when is_atom(code) do
    %{
      "operation_id" => operation["operation_id"],
      "status" => "rejected",
      "code" => Atom.to_string(code)
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
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp check_expected_revision(group, operation) do
    case Map.get(operation, "expected_revision") do
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
    outstanding = outstanding_deposit(group.id, group.deposit_due_cents)

    if amount_cents <= outstanding do
      :ok
    else
      {:error, :payment_exceeds_outstanding}
    end
  end

  defp outstanding_deposit(group_id, deposit_due_cents) do
    max(deposit_due_cents - Finance.cash_held(group_id) - Finance.credit_applied(group_id), 0)
  end

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

  defp convert_cash_movements(group_id, new_kind) do
    Repo.update_all(
      from(m in CashMovement, where: [group_id: ^group_id, kind: "held"]),
      set: [kind: new_kind]
    )
  end

  defp issue_credit_lot(group, operation_id, cancelled_on, paid_cents)
       when paid_cents > 0 do
    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        original_amount_cents: bonus_amount(paid_cents),
        remaining_cents: bonus_amount(paid_cents),
        expires_on: Date.add(cancelled_on, @credit_available_days + 1)
      })

    lot.original_amount_cents
  end

  defp issue_credit_lot(_group, _operation_id, _cancelled_on, _paid_cents), do: 0

  defp ensure_credit_available(guest_id, as_of, amount_cents) do
    if Finance.available_credit(guest_id, as_of) >= amount_cents do
      :ok
    else
      {:error, :insufficient_credit}
    end
  end

  defp consume_credit_lots(group_id, guest_id, as_of, amount_cents) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.expires_on > ^as_of and l.remaining_cents > 0,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )

    Enum.reduce_while(lots, amount_cents, fn lot, remaining_need ->
      take = min(lot.remaining_cents, remaining_need)

      from(l in CreditLot,
        where: l.id == ^lot.id,
        update: [inc: [remaining_cents: -(^take)]]
      )
      |> Repo.update_all([])

      Repo.insert!(%CreditApplication{
        group_id: group_id,
        credit_lot_id: lot.id,
        amount_cents: take
      })

      case remaining_need - take do
        0 -> {:halt, 0}
        left -> {:cont, left}
      end
    end)
  end

  # Returns applied hotel credit to its original lots on a refundable
  # cancellation. Lots whose expiry is already past on the cancellation date
  # expire immediately instead of becoming available again.
  defp restore_applied_credit(group, occurred_on) do
    applications =
      Repo.all(
        from a in CreditApplication,
          where: a.group_id == ^group.id,
          join: l in CreditLot,
          on: l.id == a.credit_lot_id,
          select: {a.amount_cents, l.id, l.expires_on}
      )

    Enum.each(applications, fn {amount_cents, lot_id, expires_on} ->
      if Date.compare(expires_on, occurred_on) == :gt do
        from(l in CreditLot,
          where: l.id == ^lot_id,
          update: [inc: [remaining_cents: ^amount_cents]]
        )
        |> Repo.update_all([])
      end
    end)

    Repo.delete_all(from a in CreditApplication, where: a.group_id == ^group.id)
  end

  defp consume_applied_credit(group) do
    Repo.delete_all(from a in CreditApplication, where: a.group_id == ^group.id)
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
end
