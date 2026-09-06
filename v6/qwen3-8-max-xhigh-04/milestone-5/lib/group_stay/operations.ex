defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in submission order and reports the outcome of
  each one.

  Each operation runs in its own transaction. A rejected operation leaves the
  domain state exactly as it was before the operation began, and processing
  continues with the next operation.

  Operations carrying an `operation_id` are durably idempotent. The first
  operation received for an identifier commits its result together with its
  domain changes, and a later retry with an equivalent payload returns the
  stored result without touching the domain. A handled rejection commits its
  idempotency record even though it changes no domain state. Reusing an
  identifier with a different payload is rejected with `operation_id_conflict`.
  An unexpected exception rolls the operation back without remembering it.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Credit.Lot
  alias GroupStay.Funding
  alias GroupStay.Funding.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Policy
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]
  @credit_bonus_percent 10
  @credit_availability_days 365

  @doc """
  Applies each operation map in order and returns one result map per
  operation, in the same order.
  """
  def submit(operations) when is_list(operations) do
    Enum.map(operations, &run/1)
  end

  @doc """
  Returns the stored result for a remembered operation identifier, or
  `:error` if the identifier has no durable record.
  """
  def fetch_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> :error
      record -> {:ok, Jason.decode!(record.result)}
    end
  end

  def fetch_result(_other), do: :error

  defp run(operation) when is_map(operation) do
    case tracked_id(operation) do
      {:ok, operation_id} -> run_tracked(operation, operation_id)
      :error -> run_untracked(operation)
    end
  end

  defp run(_other), do: rejection(nil, :invalid_operation)

  defp tracked_id(operation) do
    case Map.get(operation, "operation_id") do
      operation_id when is_binary(operation_id) and operation_id != "" -> {:ok, operation_id}
      _other -> :error
    end
  end

  defp run_tracked(operation, operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> process_and_record(operation, operation_id)
      record -> replay(record, operation, operation_id)
    end
  end

  defp run_untracked(operation) do
    outcome =
      Repo.transaction(fn ->
        case apply_operation(operation) do
          {:ok, result} -> result
          {:error, rejection} -> Repo.rollback(rejection)
        end
      end)

    case outcome do
      {:ok, result} -> result
      {:error, {code, details}} -> rejection(operation["operation_id"], code, details)
    end
  end

  defp replay(record, operation, operation_id) do
    if equivalent_payload?(record, operation) do
      Jason.decode!(record.result)
    else
      rejection(operation_id, :operation_id_conflict)
    end
  end

  # Object key order is irrelevant once parsed into maps, while array order
  # and values remain significant. Strict comparison keeps distinct JSON
  # representations (such as 5000 and 5000.0) from replaying each other.
  defp equivalent_payload?(record, operation) do
    Jason.decode!(record.payload) === operation
  end

  defp process_and_record(operation, operation_id) do
    outcome =
      Repo.transaction(fn ->
        Repo.query!("SAVEPOINT operation_apply")

        result =
          case apply_operation(operation) do
            {:ok, result} ->
              Repo.query!("RELEASE SAVEPOINT operation_apply")
              result

            {:error, {code, details}} ->
              Repo.query!("ROLLBACK TO SAVEPOINT operation_apply")
              Repo.query!("RELEASE SAVEPOINT operation_apply")
              rejection(operation_id, code, details)
          end

        case insert_record(operation_id, operation, result) do
          {:ok, _record} ->
            result

          {:error, changeset} ->
            if Keyword.has_key?(changeset.errors, :operation_id) do
              Repo.rollback(:operation_id_race)
            else
              raise "unexpected failure recording operation #{inspect(operation_id)}"
            end
        end
      end)

    case outcome do
      {:ok, result} ->
        result

      {:error, :operation_id_race} ->
        case Repo.get_by(Record, operation_id: operation_id) do
          nil -> rejection(operation_id, :operation_id_conflict)
          record -> replay(record, operation, operation_id)
        end
    end
  end

  defp insert_record(operation_id, operation, result) do
    %Record{}
    |> Changeset.change(%{
      operation_id: operation_id,
      type: Map.get(operation, "type"),
      payload: Jason.encode!(operation),
      result: Jason.encode!(result)
    })
    |> Changeset.unique_constraint(:operation_id)
    |> Repo.insert()
  end

  defp apply_operation(%{"type" => "open_group"} = op), do: open_group(op)
  defp apply_operation(%{"type" => "record_cash_payment"} = op), do: record_cash_payment(op)
  defp apply_operation(%{"type" => "reschedule_group"} = op), do: reschedule_group(op)
  defp apply_operation(%{"type" => "cancel_group"} = op), do: cancel_group(op)
  defp apply_operation(%{"type" => "cancel_rooms"} = op), do: cancel_rooms(op)
  defp apply_operation(%{"type" => "apply_hotel_credit"} = op), do: apply_hotel_credit(op)
  defp apply_operation(%{"type" => "reduce_cash_payment"} = op), do: reduce_cash_payment(op)
  defp apply_operation(%{"type" => "charge_back_payment"} = op), do: charge_back_payment(op)
  defp apply_operation(%{"type" => "transfer_deposit"} = op), do: transfer_deposit(op)
  defp apply_operation(_op), do: reject(:invalid_operation)

  ## open_group

  defp open_group(op) do
    with {:ok, occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, group_id} <- fetch_identifier(op, "group_id"),
         {:ok, guest_id} <- fetch_identifier(op, "guest_id"),
         {:ok, property_id} <- fetch_identifier(op, "property_id"),
         {:ok, arrival_on} <- parse_date(op["arrival_on"]),
         {:ok, departure_on} <- parse_date(op["departure_on"]),
         {:ok, rate_plan} <- fetch_string(op, "rate_plan"),
         {:ok, rooms} <- fetch_rooms(op),
         :ok <- ensure_group_available(group_id),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rooms(rooms),
         :ok <- validate_rate_plan(rate_plan) do
      create_group(op, %{
        occurred_on: occurred_on,
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      })
    end
  end

  defp create_group(op, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    rooms =
      Enum.map(attrs.rooms, fn %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
        lodging = nights * rate

        %Room{
          room_id: room_id,
          nightly_rate_cents: rate,
          status: "active",
          lodging_cents: lodging,
          deposit_due_cents: Funding.room_deposit(attrs.rate_plan, lodging)
        }
      end)

    lodging_total_cents =
      Enum.reduce(rooms, 0, fn room, total -> total + room.lodging_cents end)

    deposit_due_cents =
      Enum.reduce(rooms, 0, fn room, total -> total + room.deposit_due_cents end)

    group =
      Repo.insert!(%Group{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        booked_on: attrs.occurred_on,
        arrival_on: attrs.arrival_on,
        departure_on: attrs.departure_on,
        rate_plan: attrs.rate_plan,
        policy_version: Policy.version_for(attrs.rate_plan, attrs.occurred_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        rooms: rooms
      })

    {:ok,
     applied(op["operation_id"], %{
       group_id: group.group_id,
       deposit_due_cents: group.deposit_due_cents,
       revision: group.revision
     })}
  rescue
    error in Ecto.ConstraintError ->
      case error.constraint do
        "groups_group_id_index" -> reject(:group_already_exists)
        _other -> reraise error, __STACKTRACE__
      end
  end

  defp ensure_group_available(group_id) do
    if Repo.get_by(Group, group_id: group_id) do
      reject(:group_already_exists)
    else
      :ok
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      reject(:invalid_stay)
    end
  end

  defp validate_rooms(rooms) do
    cond do
      rooms == [] -> reject(:invalid_rooms)
      Enum.any?(rooms, &invalid_room?/1) -> reject(:invalid_rooms)
      duplicate_room_ids?(rooms) -> reject(:invalid_rooms)
      true -> :ok
    end
  end

  defp invalid_room?(room) do
    case room do
      %{"room_id" => room_id, "nightly_rate_cents" => rate}
      when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
        false

      _other ->
        true
    end
  end

  defp duplicate_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(ids) != length(Enum.uniq(ids))
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans do
      :ok
    else
      reject(:invalid_rate_plan)
    end
  end

  ## record_cash_payment

  defp record_cash_payment(op) do
    with {:ok, _occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, group_id} <- fetch_identifier(op, "group_id"),
         {:ok, amount_cents} <- fetch_amount(op),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- revision_check(group, op),
         :ok <- active_check(group),
         :ok <- payment_check(group, amount_cents) do
      Funding.allocate_cash(group, amount_cents, op["operation_id"])

      update_group(op, group, %{deposit_paid_cents: group.deposit_paid_cents + amount_cents}, fn
        updated ->
          %{
            group_id: updated.group_id,
            amount_cents: amount_cents,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          }
      end)
    end
  end

  defp fetch_amount(op) do
    case Map.fetch(op, "amount_cents") do
      {:ok, amount_cents} -> {:ok, amount_cents}
      :error -> reject(:invalid_operation)
    end
  end

  defp payment_check(group, amount_cents) do
    cond do
      not is_integer(amount_cents) or amount_cents <= 0 -> reject(:invalid_amount)
      amount_cents > outstanding(group) -> reject(:payment_exceeds_outstanding)
      true -> :ok
    end
  end

  ## reschedule_group

  defp reschedule_group(op) do
    with {:ok, occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, group_id} <- fetch_identifier(op, "group_id"),
         {:ok, new_arrival_on} <- parse_date(op["new_arrival_on"]),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- revision_check(group, op),
         :ok <- active_check(group),
         :ok <- reschedule_check(occurred_on, new_arrival_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, nights)

      update_group(
        op,
        group,
        %{arrival_on: new_arrival_on, departure_on: new_departure_on},
        fn updated ->
          %{
            group_id: updated.group_id,
            new_arrival_on: Date.to_iso8601(updated.arrival_on),
            new_departure_on: Date.to_iso8601(updated.departure_on),
            policy_version: updated.policy_version,
            refundable_until: Policy.refundable_until_iso(updated),
            revision: updated.revision
          }
        end
      )
    end
  end

  defp reschedule_check(occurred_on, new_arrival_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      reject(:invalid_stay)
    end
  end

  ## cancel_group

  defp cancel_group(op) do
    with {:ok, occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, group_id} <- fetch_identifier(op, "group_id"),
         {:ok, refund_method} <- fetch_refund_method(op),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- revision_check(group, op),
         :ok <- active_check(group) do
      rooms = Funding.active_rooms(group.rooms)

      settle_selected_rooms(op, group, rooms, occurred_on, refund_method, fn updated, amounts ->
        %{
          group_id: updated.group_id,
          refunded_cents: amounts.refunded,
          retained_cents: amounts.retained,
          credit_issued_cents: amounts.credit_issued,
          revision: updated.revision
        }
      end)
    end
  end

  ## cancel_rooms

  defp cancel_rooms(op) do
    with {:ok, occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, group_id} <- fetch_identifier(op, "group_id"),
         {:ok, room_ids} <- fetch_room_ids(op),
         {:ok, refund_method} <- fetch_refund_method(op),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- revision_check(group, op),
         :ok <- active_check(group),
         {:ok, rooms} <- validate_room_ids(group, room_ids) do
      settle_selected_rooms(op, group, rooms, occurred_on, refund_method, fn updated, amounts ->
        %{
          group_id: updated.group_id,
          cancelled_room_ids: Enum.map(rooms, & &1.room_id),
          refunded_cents: amounts.refunded,
          retained_cents: amounts.retained,
          credit_issued_cents: amounts.credit_issued,
          revision: updated.revision
        }
      end)
    end
  end

  defp fetch_room_ids(op) do
    case Map.get(op, "room_ids") do
      room_ids when is_list(room_ids) -> {:ok, room_ids}
      _other -> reject(:invalid_operation)
    end
  end

  # All supplied identifiers must identify distinct, active rooms of the group.
  # The matched rooms are returned in the group's original room order.
  defp validate_room_ids(group, room_ids) do
    cond do
      room_ids == [] ->
        reject(:invalid_rooms)

      Enum.any?(room_ids, &(not is_binary(&1) or &1 == "")) ->
        reject(:invalid_rooms)

      length(Enum.uniq(room_ids)) != length(room_ids) ->
        reject(:invalid_rooms)

      true ->
        active = Funding.active_rooms(group.rooms)
        active_ids = MapSet.new(Enum.map(active, & &1.room_id))

        if Enum.all?(room_ids, &MapSet.member?(active_ids, &1)) do
          {:ok, Enum.filter(active, &(&1.room_id in room_ids))}
        else
          reject(:invalid_rooms)
        end
    end
  end

  defp fetch_refund_method(op) do
    case Map.get(op, "refund_method") do
      nil ->
        {:ok, "cash"}

      "cash" ->
        {:ok, "cash"}

      "hotel_credit" ->
        # The issued lot records the cancellation's operation identifier.
        with {:ok, _operation_id} <- fetch_identifier(op, "operation_id") do
          {:ok, "hotel_credit"}
        end

      _other ->
        reject(:invalid_operation)
    end
  end

  # Settles the selected rooms using the cancellation date, policy, refund
  # method, bonus, and restoration rules. Unpaid deposit for the selected rooms
  # ceases to be due; other rooms and their allocations are unchanged. If no
  # active rooms remain, the group becomes cancelled.
  defp settle_selected_rooms(op, group, rooms, occurred_on, refund_method, result_fn) do
    refundable = Policy.refundable?(group, occurred_on)

    if refund_method == "hotel_credit" and not refundable do
      reject(:refund_method_not_available)
    else
      do_settle_rooms(op, group, rooms, occurred_on, refund_method, refundable, result_fn)
    end
  end

  defp do_settle_rooms(op, group, rooms, occurred_on, refund_method, refundable, result_fn) do
    room_ids = Enum.map(rooms, & &1.room_id)
    room_set = MapSet.new(room_ids)
    held = Funding.held_for(group.id)

    cash_allocs =
      Enum.filter(held, fn a -> a.kind == "cash" and MapSet.member?(room_set, a.room_id) end)

    credit_allocs =
      Enum.filter(held, fn a -> a.kind == "credit" and MapSet.member?(room_set, a.room_id) end)

    cash_total = sum_amounts(cash_allocs)
    credit_total = sum_amounts(credit_allocs)

    amounts =
      cond do
        refundable and refund_method == "cash" ->
          Funding.reclassify_all(cash_allocs, "refunded")
          restore_credit(credit_allocs, occurred_on)
          %{refunded: cash_total, retained: 0, converted: 0, credit_issued: 0}

        refundable and refund_method == "hotel_credit" ->
          {lot_value, lot_id} = issue_settlement_lot(op, group, cash_total, occurred_on)
          mark_converted(cash_allocs, lot_id)
          restore_credit(credit_allocs, occurred_on)
          %{refunded: 0, retained: 0, converted: cash_total, credit_issued: lot_value}

        true ->
          Funding.reclassify_all(cash_allocs, "retained")
          Enum.each(credit_allocs, &Repo.delete!/1)
          %{refunded: 0, retained: cash_total, converted: 0, credit_issued: 0}
      end

    cancelled_due = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))
    cancelled_lodging = Enum.reduce(rooms, 0, &((&1.lodging_cents || 0) + &2))

    updated_rooms =
      Enum.map(group.rooms, fn room ->
        if room.room_id in room_ids, do: %{room | status: "cancelled"}, else: room
      end)

    new_status =
      if Enum.any?(updated_rooms, &(&1.status == "active")),
        do: group.status,
        else: "cancelled"

    attrs = %{
      status: new_status,
      rooms: updated_rooms,
      lodging_total_cents: group.lodging_total_cents - cancelled_lodging,
      deposit_due_cents: group.deposit_due_cents - cancelled_due,
      deposit_paid_cents: group.deposit_paid_cents - cash_total - credit_total,
      credit_paid_cents: group.credit_paid_cents - credit_total,
      refunded_cents: group.refunded_cents + amounts.refunded,
      retained_cents: group.retained_cents + amounts.retained,
      converted_cents: group.converted_cents + amounts.converted
    }

    update_group(op, group, attrs, fn updated -> result_fn.(updated, amounts) end)
  end

  defp sum_amounts(allocations) do
    Enum.reduce(allocations, 0, &(&1.amount_cents + &2))
  end

  defp issue_settlement_lot(_op, _group, 0, _occurred_on), do: {0, nil}

  defp issue_settlement_lot(op, group, cash_total, occurred_on) do
    bonus_cents = Funding.round_half_up(cash_total * @credit_bonus_percent, 100)
    total_cents = cash_total + bonus_cents

    lot =
      Repo.insert!(%Lot{
        guest_id: group.guest_id,
        source_operation_id: op["operation_id"],
        initial_cents: total_cents,
        remaining_cents: total_cents,
        expires_on: Date.add(occurred_on, @credit_availability_days + 1)
      })

    {total_cents, lot.id}
  end

  defp mark_converted(_cash_allocs, nil), do: :ok

  defp mark_converted(cash_allocs, lot_id) do
    Enum.each(cash_allocs, fn allocation ->
      allocation
      |> Changeset.change(disposition: "converted", converted_lot_id: lot_id)
      |> Repo.update!()
    end)
  end

  # Restores applied credit to its original lots. A restoration is absorbed by
  # any unrecovered clawback on the lot before the expiry check; only the excess
  # becomes available again (or expires under the existing rules).
  defp restore_credit(credit_allocs, occurred_on) do
    credit_allocs
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, allocations} ->
      amount = sum_amounts(allocations)
      lot = Repo.get!(Lot, lot_id)
      clawback = lot.unrecovered_clawback_cents || 0
      absorbed = min(amount, clawback)
      excess = amount - absorbed

      changes = %{unrecovered_clawback_cents: clawback - absorbed}

      changes =
        if Date.compare(lot.expires_on, occurred_on) == :gt do
          Map.put(changes, :remaining_cents, lot.remaining_cents + excess)
        else
          changes
        end

      lot
      |> Changeset.change(changes)
      |> Repo.update!()

      Enum.each(allocations, &Repo.delete!/1)
    end)
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(op) do
    with {:ok, occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, group_id} <- fetch_identifier(op, "group_id"),
         {:ok, amount_cents} <- fetch_amount(op),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- revision_check(group, op),
         :ok <- active_check(group),
         :ok <- amount_check(amount_cents),
         :ok <- credit_check(group, amount_cents, occurred_on),
         :ok <- outstanding_check(group, amount_cents) do
      lot_portions = consume_credit(group, amount_cents, occurred_on)
      Funding.allocate_credit(group, lot_portions)

      update_group(
        op,
        group,
        %{
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          credit_paid_cents: group.credit_paid_cents + amount_cents
        },
        fn updated ->
          %{
            group_id: updated.group_id,
            amount_cents: amount_cents,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          }
        end
      )
    end
  end

  defp amount_check(amount_cents) do
    if is_integer(amount_cents) and amount_cents > 0 do
      :ok
    else
      reject(:invalid_amount)
    end
  end

  defp credit_check(group, amount_cents, occurred_on) do
    if available_credit(group.guest_id, occurred_on) >= amount_cents do
      :ok
    else
      reject(:insufficient_credit)
    end
  end

  defp outstanding_check(group, amount_cents) do
    if amount_cents > outstanding(group) do
      reject(:payment_exceeds_outstanding)
    else
      :ok
    end
  end

  defp available_credit(guest_id, as_of) do
    query =
      from lot in Lot,
        where: lot.guest_id == ^guest_id and lot.expires_on > ^as_of,
        select: sum(lot.remaining_cents)

    Repo.one(query) || 0
  end

  # Consumes lots by earliest expiry (then source operation) and returns the
  # consumed portions as `{lot_id, amount_cents}` in consumption order.
  defp consume_credit(group, amount_cents, occurred_on) do
    lots =
      Repo.all(
        from lot in Lot,
          where:
            lot.guest_id == ^group.guest_id and lot.expires_on > ^occurred_on and
              lot.remaining_cents > 0,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

    {portions, _remaining} =
      Enum.reduce(lots, {[], amount_cents}, fn lot, {portions, remaining} ->
        if remaining == 0 do
          {portions, remaining}
        else
          consumed = min(lot.remaining_cents, remaining)

          lot
          |> Changeset.change(remaining_cents: lot.remaining_cents - consumed)
          |> Repo.update!()

          {[{lot.id, consumed} | portions], remaining - consumed}
        end
      end)

    Enum.reverse(portions)
  end

  ## reduce_cash_payment

  defp reduce_cash_payment(op) do
    with {:ok, _occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, payment_operation_id} <- fetch_identifier(op, "payment_operation_id"),
         {:ok, amount_cents} <- fetch_amount(op),
         {:ok, record} <- fetch_operation_record(payment_operation_id),
         {:ok, group_id} <-
           applied_cash_payment_group(record, :payment_not_reducible),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- revision_check(group, op),
         :ok <- positive_amount_check(amount_cents),
         {:ok, held} <- held_cash_for_payment(payment_operation_id),
         :ok <- reduction_limit_check(held, amount_cents),
         {:ok, removed_by_group} <- remove_held_cash(held, amount_cents),
         :ok <- bump_other_groups(removed_by_group, group.id) do
      removed_from_group = Map.get(removed_by_group, group.id, 0)

      update_group(
        op,
        group,
        %{deposit_paid_cents: group.deposit_paid_cents - removed_from_group},
        fn updated ->
          %{
            payment_operation_id: payment_operation_id,
            group_id: updated.group_id,
            amount_cents: amount_cents,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          }
        end
      )
    end
  end

  # Held allocations from one payment can span groups once deposits have been
  # transferred; remove them in reverse allocation order across all groups.
  defp remove_held_cash(held, amount_cents) do
    ordered = Enum.sort_by(held, & &1.global_sequence, :desc)
    {:ok, Funding.remove_in_order(ordered, amount_cents, "reduced")}
  end

  # An applied operation increments the revision of every group whose state it
  # changes. Revision guards remain preconditions only for the addressed group;
  # other affected groups increment without being guarded by the request.
  defp bump_other_groups(removed_by_group, addressed_internal_id) do
    removed_by_group
    |> Map.delete(addressed_internal_id)
    |> Enum.reduce_while(:ok, fn {internal_id, amount}, :ok ->
      other = Repo.get!(Group, internal_id)

      case bump_group(other, %{deposit_paid_cents: other.deposit_paid_cents - amount}) do
        {:ok, _updated} -> {:cont, :ok}
        rejection -> {:halt, rejection}
      end
    end)
  end

  defp positive_amount_check(amount_cents) do
    if is_integer(amount_cents) and amount_cents > 0 do
      :ok
    else
      reject(:invalid_amount)
    end
  end

  defp held_cash_for_payment(payment_operation_id) do
    held = Funding.held_for_payment(payment_operation_id)
    held_total = sum_amounts(held)

    cond do
      held_total == 0 -> reject(:payment_not_reducible)
      true -> {:ok, held}
    end
  end

  # A smaller positive amount could succeed, but the requested amount exceeds
  # the payment's currently held cash.
  defp reduction_limit_check(held, amount_cents) do
    if amount_cents > sum_amounts(held) do
      reject(:reduction_exceeds_held_cash)
    else
      :ok
    end
  end

  ## charge_back_payment

  defp charge_back_payment(op) do
    with {:ok, _occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, payment_operation_id} <- fetch_identifier(op, "payment_operation_id"),
         {:ok, record} <- fetch_operation_record(payment_operation_id),
         {:ok, group_id} <-
           applied_cash_payment_group(record, :payment_not_chargeable),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- revision_check(group, op),
         {:ok, allocations} <- chargeable_allocations(payment_operation_id) do
      apply_chargeback(op, group, payment_operation_id, allocations)
    end
  end

  # A payment is chargeable unless it was already charged back or every cent of
  # its recorded cash has already been reduced.
  defp chargeable_allocations(payment_operation_id) do
    allocations = Funding.all_for_payment(payment_operation_id)

    already_charged_back = Enum.any?(allocations, &(&1.disposition == "charged_back"))

    remaining =
      allocations
      |> Enum.filter(&(&1.disposition in ["held", "refunded", "retained", "converted"]))
      |> sum_amounts()

    cond do
      already_charged_back -> reject(:payment_not_chargeable)
      remaining == 0 -> reject(:payment_not_chargeable)
      true -> {:ok, allocations}
    end
  end

  defp apply_chargeback(op, group, payment_operation_id, allocations) do
    held = Enum.filter(allocations, &(&1.disposition == "held"))
    refunded = Enum.filter(allocations, &(&1.disposition == "refunded"))
    retained = Enum.filter(allocations, &(&1.disposition == "retained"))
    converted = Enum.filter(allocations, &(&1.disposition == "converted"))

    held_amount = sum_amounts(held)

    # Revoke the credit entitlement created by the converted principal before
    # reclassifying it, while the contributions are still readable.
    revoke_entitlements(converted, payment_operation_id)

    removed_by_group =
      Funding.remove_in_order(
        Enum.sort_by(held, & &1.global_sequence, :desc),
        held_amount,
        "charged_back"
      )

    Funding.reclassify_all(refunded, "charged_back")
    Funding.reclassify_all(retained, "charged_back")
    Funding.reclassify_all(converted, "charged_back")

    charged_back_cents =
      held_amount + sum_amounts(refunded) + sum_amounts(retained) + sum_amounts(converted)

    with :ok <- bump_other_groups(removed_by_group, group.id) do
      update_group(
        op,
        group,
        %{deposit_paid_cents: group.deposit_paid_cents - Map.get(removed_by_group, group.id, 0)},
        fn updated ->
          %{
            payment_operation_id: payment_operation_id,
            group_id: updated.group_id,
            charged_back_cents: charged_back_cents,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          }
        end
      )
    end
  end

  # Revokes the payment's entitlement from each lot its converted cash funded.
  # Entitlement is removed from the lot's remaining balance first; any amount
  # that cannot be removed becomes the lot's unrecovered clawback.
  defp revoke_entitlements(converted_allocations, payment_operation_id) do
    converted_allocations
    |> Enum.map(& &1.converted_lot_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn lot_id ->
      entitlement = entitlement_for_lot(lot_id, payment_operation_id)
      lot = Repo.get!(Lot, lot_id)

      removed = min(lot.remaining_cents, entitlement)
      clawback = lot.unrecovered_clawback_cents || 0

      lot
      |> Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: clawback + (entitlement - removed)
      )
      |> Repo.update!()
    end)
  end

  # The payment's entitlement in one lot is the standard 10%-bonus value of the
  # settled cash through that payment minus the bonus value through the
  # preceding contributor, in the funding order used by room accounting with the
  # unattributed senior block first. The differences telescope exactly to the
  # issued lot.
  defp entitlement_for_lot(lot_id, payment_operation_id) do
    contributors =
      Repo.all(
        from a in Allocation,
          where: a.converted_lot_id == ^lot_id,
          order_by: [asc: a.fill_sequence, asc: a.id]
      )
      |> contributors_in_order()

    {_cum, entitlement} =
      Enum.reduce(contributors, {0, 0}, fn {contributor, amount}, {cum, entitlement} ->
        new_cum = cum + amount

        entitlement =
          if contributor == payment_operation_id do
            entitlement + (bonus_value(new_cum) - bonus_value(cum))
          else
            entitlement
          end

        {new_cum, entitlement}
      end)

    entitlement
  end

  # Groups contributions by payment identifier (nil for the unattributed senior
  # block) while preserving funding order.
  defp contributors_in_order(allocations) do
    {order, sums} =
      Enum.reduce(allocations, {[], %{}}, fn allocation, {order, sums} ->
        key = allocation.payment_operation_id

        sums = Map.update(sums, key, allocation.amount_cents, &(&1 + allocation.amount_cents))
        order = if key in order, do: order, else: order ++ [key]
        {order, sums}
      end)

    Enum.map(order, fn key -> {key, Map.fetch!(sums, key)} end)
  end

  defp bonus_value(cash_cents) do
    cash_cents + Funding.round_half_up(cash_cents * @credit_bonus_percent, 100)
  end

  ## transfer_deposit

  # Moves held funding from one active group to another active group of the
  # same guest without settling or revaluing anything. Existence is resolved
  # source first, then destination; both revision guards are checked before
  # the transfer rules.
  defp transfer_deposit(op) do
    with {:ok, _occurred_on} <- parse_date(op["occurred_on"]),
         {:ok, source_group_id} <- fetch_identifier(op, "source_group_id"),
         {:ok, destination_group_id} <- fetch_identifier(op, "destination_group_id"),
         {:ok, amount_cents} <- fetch_amount(op),
         {:ok, source} <- fetch_transfer_group(source_group_id),
         {:ok, destination} <- fetch_transfer_group(destination_group_id),
         {:ok, source} <- revision_check(source, op),
         {:ok, destination} <- destination_revision_check(destination, op),
         :ok <- transfer_pair_check(source, destination),
         :ok <- transfer_active_check(source),
         :ok <- transfer_active_check(destination),
         :ok <- amount_check(amount_cents),
         :ok <- held_funding_check(source, amount_cents),
         :ok <- destination_outstanding_check(destination, amount_cents) do
      perform_transfer(op, source, destination, amount_cents)
    end
  end

  defp fetch_transfer_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> reject(:group_not_found, %{group_id: group_id})
      group -> {:ok, group}
    end
  end

  defp destination_revision_check(%Group{} = group, op) do
    case Map.get(op, "destination_expected_revision") do
      nil ->
        {:ok, group}

      expected_revision ->
        if expected_revision == group.revision do
          {:ok, group}
        else
          reject(:stale_revision, %{
            group_id: group.group_id,
            expected_revision: expected_revision,
            actual_revision: group.revision
          })
        end
    end
  end

  defp transfer_pair_check(source, destination) do
    if source.group_id == destination.group_id or source.guest_id != destination.guest_id do
      reject(:invalid_transfer)
    else
      :ok
    end
  end

  defp transfer_active_check(%Group{status: "active"}), do: :ok

  defp transfer_active_check(%Group{} = group),
    do: reject(:group_not_active, %{group_id: group.group_id})

  # Held funding is cash and hotel credit currently allocated to active rooms.
  defp held_funding_check(source, amount_cents) do
    held_total = sum_amounts(Funding.held_for(source.id))

    if amount_cents > held_total do
      reject(:transfer_exceeds_held_funding)
    else
      :ok
    end
  end

  defp destination_outstanding_check(destination, amount_cents) do
    if amount_cents > outstanding(destination) do
      reject(:transfer_exceeds_outstanding)
    else
      :ok
    end
  end

  # Draws the amount from the source's held allocations in reverse allocation
  # order, regardless of funding kind, and fills the destination's active
  # rooms in their original order, preserving the order in which units were
  # drawn. Each moved allocation keeps its provenance. No settlement, bonus,
  # expiry change, or ledger total results from the move.
  defp perform_transfer(op, source, destination, amount_cents) do
    moves =
      source.id
      |> Funding.held_for()
      |> Enum.reverse()
      |> Funding.draw_allocations(amount_cents)

    Funding.receive_transferred_funding(destination, moves)

    credit_moved =
      moves
      |> Enum.filter(&(&1.kind == "credit"))
      |> Enum.reduce(0, &(&1.amount_cents + &2))

    with {:ok, updated_source} <-
           bump_group(source, %{
             deposit_paid_cents: source.deposit_paid_cents - amount_cents,
             credit_paid_cents: source.credit_paid_cents - credit_moved
           }),
         {:ok, updated_destination} <-
           bump_group(destination, %{
             deposit_paid_cents: destination.deposit_paid_cents + amount_cents,
             credit_paid_cents: destination.credit_paid_cents + credit_moved
           }) do
      {:ok,
       applied(op["operation_id"], %{
         source_group_id: updated_source.group_id,
         destination_group_id: updated_destination.group_id,
         amount_cents: amount_cents,
         source_outstanding_deposit_cents: outstanding(updated_source),
         destination_outstanding_deposit_cents: outstanding(updated_destination),
         source_revision: updated_source.revision,
         destination_revision: updated_destination.revision
       })}
    end
  end

  ## payment record helpers

  defp fetch_operation_record(payment_operation_id) do
    case Repo.get_by(Record, operation_id: payment_operation_id) do
      nil -> reject(:operation_not_found)
      record -> {:ok, record}
    end
  end

  # Returns the group of an applied cash payment, or rejects with the given code
  # when the record is not an applied cash payment.
  defp applied_cash_payment_group(record, rejection_code) do
    with "record_cash_payment" <- record.type,
         {:ok, result} <- Jason.decode(record.result),
         %{"status" => "applied", "group_id" => group_id} <- result,
         true <- is_binary(group_id) do
      {:ok, group_id}
    else
      _other -> reject(rejection_code)
    end
  end

  ## shared helpers

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> reject(:group_not_found)
      group -> {:ok, group}
    end
  end

  defp revision_check(%Group{} = group, op) do
    case Map.get(op, "expected_revision") do
      nil ->
        {:ok, group}

      expected_revision ->
        if expected_revision == group.revision do
          {:ok, group}
        else
          reject(:stale_revision, %{
            group_id: group.group_id,
            expected_revision: expected_revision,
            actual_revision: group.revision
          })
        end
    end
  end

  defp active_check(%Group{status: "active"}), do: :ok
  defp active_check(%Group{}), do: reject(:group_not_active)

  defp update_group(op, %Group{} = group, attrs, result) do
    with {:ok, updated} <- bump_group(group, attrs) do
      {:ok, applied(op["operation_id"], result.(updated))}
    end
  end

  # Applies the attrs to the group under its optimistic revision lock,
  # incrementing its revision exactly once.
  defp bump_group(%Group{} = group, attrs) do
    group
    |> Changeset.change(attrs)
    |> Changeset.optimistic_lock(:revision)
    |> Repo.update(force: true)
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> concurrent_modification(group.group_id)
    end
  end

  defp concurrent_modification(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        reject(:group_not_found)

      group ->
        reject(:stale_revision, %{
          group_id: group_id,
          expected_revision: nil,
          actual_revision: group.revision
        })
    end
  end

  defp outstanding(%Group{} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp fetch_identifier(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> reject(:invalid_operation)
    end
  end

  defp fetch_string(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> reject(:invalid_operation)
    end
  end

  defp fetch_rooms(op) do
    case Map.get(op, "rooms") do
      rooms when is_list(rooms) -> {:ok, rooms}
      _other -> reject(:invalid_operation)
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> reject(:invalid_operation)
    end
  end

  defp parse_date(_other), do: reject(:invalid_operation)

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp rejection(operation_id, code, details \\ %{}) do
    Map.merge(
      %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)},
      details
    )
  end

  defp reject(code, details \\ %{}), do: {:error, {code, details}}
end
