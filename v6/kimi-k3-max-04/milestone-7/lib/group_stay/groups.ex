defmodule GroupStay.Groups do
  @moduledoc """
  The GroupStay domain: applying partner operations to group reservations and
  reading reservation and finance state.

  Partner operations are applied one at a time, each inside its own
  transaction. An operation either applies fully or is rejected.

  Operations carrying an `operation_id` are made durably idempotent: the first
  submission commits its result together with the idempotency record (handled
  rejections commit the record while leaving domain state unchanged), an
  equivalent retry returns the stored result verbatim, and a conflicting reuse
  of the identifier is rejected without replacing the stored record.
  Operations without an identifier keep the legacy all-or-nothing rollback
  behavior.

  Cash and credit fund the active rooms' deposits in the rooms' original
  order, filling one room before moving to the next. Held cash is attributed
  to the funding operation that supplied it (or to nobody, for funding
  without a durable operation identity) so that cancellations, reductions,
  and chargebacks can settle exactly the cash they address.
  """

  import Ecto.Query

  alias GroupStay.Finance
  alias GroupStay.Money
  alias GroupStay.Repo

  alias GroupStay.Groups.{
    CashAllocation,
    CreditApplication,
    CreditEntitlement,
    CreditLot,
    Group,
    OperationRecord,
    PaymentDisposition,
    Room
  }

  @rate_plans ["flexible", "advance_purchase"]
  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  @credit_lifetime_days 365
  @policy_cutover ~D[2027-01-01]

  # --- Applying operations --------------------------------------------------

  @doc """
  Applies every operation in the list, in order, and returns one result per
  operation (applied or rejected) in the same order. A rejected operation
  never stops later operations.
  """
  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Applies a single operation inside its own transaction. Returns a result map
  with `status` of either `"applied"` or `"rejected"`.

  When the operation carries a string `operation_id`, its first submission is
  remembered durably: the computed result (applied or rejected) commits
  together with the idempotency record. An equivalent retry returns the stored
  result without re-reading or changing domain state; a re-use with a
  different payload is rejected with `operation_id_conflict`. An unexpected
  exception rolls the current operation back and is deliberately not
  remembered.
  """
  def apply_operation(operation) do
    case operation_id(operation) do
      nil -> apply_operation_once(operation)
      op_id -> apply_idempotent(operation, op_id)
    end
  end

  # Legacy processing for operations that do not carry an identifier: applied
  # operations commit, rejected operations roll back entirely.
  defp apply_operation_once(operation) do
    case Repo.transaction(fn ->
           case process(operation) do
             {:applied, result} -> result
             {:rejected, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp apply_idempotent(operation, op_id) do
    outcome =
      Repo.transaction(fn ->
        case Repo.get_by(OperationRecord, operation_id: op_id) do
          nil -> remember(operation, op_id)
          record -> replay_or_conflict(operation, record)
        end
      end)

    case outcome do
      {:ok, result} ->
        result

      # Lost an insert race against the same identifier (or an undeclared
      # constraint fired): try the whole cycle again from a fresh lookup.
      {:error, :retry} ->
        apply_idempotent(operation, op_id)
    end
  end

  defp operation_id(operation) when is_map(operation) do
    case Map.get(operation, "operation_id") do
      id when is_binary(id) -> id
      _other -> nil
    end
  end

  defp operation_id(_operation), do: nil

  # First submission for this identifier: process the operation and commit
  # the idempotency record together with any domain changes. Handled
  # rejections commit only the record; unexpected exceptions roll everything
  # back and are not remembered.
  defp remember(operation, op_id) do
    {status, result} =
      case process(operation) do
        {:applied, result} -> {"applied", result}
        {:rejected, result} -> {"rejected", result}
      end

    changeset =
      OperationRecord.changeset(%{
        operation_id: op_id,
        type: retained_type(operation),
        status: status,
        request: Jason.encode!(operation),
        result: Jason.encode!(result)
      })

    case Repo.insert(changeset) do
      {:ok, _record} -> result
      {:error, _changeset} -> Repo.rollback(:retry)
    end
  rescue
    Ecto.ConstraintError -> Repo.rollback(:retry)
  end

  # The complete submitted content and the stored result are JSON-encoded;
  # decoded maps ignore object key order, so equivalent payloads compare
  # equal while array order and values remain significant.
  defp replay_or_conflict(operation, record) do
    if Jason.decode!(record.request) == operation do
      Jason.decode!(record.result)
    else
      reject_result(operation, "operation_id_conflict")
    end
  end

  # Only a valid binary type is retained; anything else was an invalid
  # operation anyway and has no type to keep.
  defp retained_type(operation) do
    case get_in_map(operation, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp process(%{"type" => type} = operation) when is_binary(type) do
    case type do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "cancel_rooms" -> cancel_rooms(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      "transfer_deposit" -> transfer_deposit(operation)
      "start_finance_reporting" -> start_finance_reporting(operation)
      "close_finance_period" -> close_finance_period(operation)
      _unknown -> reject(operation, "invalid_operation")
    end
  end

  defp process(operation), do: reject(operation, "invalid_operation")

  # --- start_finance_reporting -------------------------------------------------

  # Reporting is on once the first applied start captures the opening
  # position; later starts are rejected. It addresses no group and has no
  # revision guard. The applied result is exactly `operation_id`, `status`,
  # and `starts_on`.
  defp start_finance_reporting(operation) do
    case Map.get(operation, "starts_on") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, starts_on} ->
            if Finance.state() do
              reject(operation, "reporting_already_started")
            else
              Finance.start!(starts_on)
              apply_result(operation, %{starts_on: Date.to_string(starts_on)})
            end

          {:error, _} ->
            reject(operation, "invalid_reporting_date")
        end

      _other ->
        reject(operation, "invalid_reporting_date")
    end
  end

  # --- close_finance_period -------------------------------------------------

  # A close applies only when reporting has started, its cutoff is on or
  # after `starts_on`, and it is strictly later than the latest successful
  # close. Everything else rejects with invalid_period, including a missing
  # or unparsable cutoff. The close addresses no group and has no revision
  # guard. The applied result is exactly operation_id, status, and
  # period_end_on.
  defp close_finance_period(operation) do
    case Map.get(operation, "period_end_on") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, period_end_on} ->
            maybe_close(operation, period_end_on)

          {:error, _} ->
            reject(operation, "invalid_period")
        end

      _other ->
        reject(operation, "invalid_period")
    end
  end

  defp maybe_close(operation, period_end_on) do
    case Finance.state() do
      nil ->
        reject(operation, "invalid_period")

      state ->
        if Date.compare(period_end_on, state.starts_on) == :lt or
             closed_before?(state, period_end_on) do
          reject(operation, "invalid_period")
        else
          Finance.close!(period_end_on)
          apply_result(operation, %{period_end_on: Date.to_string(period_end_on)})
        end
    end
  end

  defp closed_before?(state, period_end_on) do
    state.closed_through != nil and
      Date.compare(period_end_on, state.closed_through) != :gt
  end

  # --- Movement posting ---------------------------------------------------------

  # Records an applied operation's finance movements. The posting date is
  # the latest of the operation's `occurred_on`, the reporting start, and
  # the day after the latest close cutoff; a close-moved date is flagged
  # late so the current day's report classifies it. Before reporting starts
  # nothing posts.
  defp record_movements(operation, movements) do
    case Finance.posting_detail(Map.get(operation, "occurred_on")) do
      nil -> :ok
      detail -> Finance.record(detail, movements)
    end
  end

  # The disposition field for each settled bucket is also the movement kind
  # mapping used by the report.
  defp settle_kind(:refunded_cents), do: "refunded"
  defp settle_kind(:retained_cents), do: "retained"
  defp settle_kind(:converted_cents), do: "converted_to_credit"

  # Settled-bucket keys inside a disposition's `settled_locations` map.
  defp location_key(:refunded_cents), do: "refunded"
  defp location_key(:retained_cents), do: "retained"
  defp location_key(:converted_cents), do: "converted"

  # --- open_group -----------------------------------------------------------

  defp open_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, booked_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- required_date(operation, "departure_on", "invalid_stay"),
         {:ok, rate_plan} <- required_string(operation, "rate_plan"),
         {:ok, rooms} <- required_rooms(operation) do
      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      }

      cond do
        Repo.get_by(Group, group_id: group_id) ->
          reject(operation, "group_already_exists")

        Date.compare(departure_on, arrival_on) != :gt ->
          reject(operation, "invalid_stay")

        not valid_rooms?(rooms) ->
          reject(operation, "invalid_rooms")

        rate_plan not in @rate_plans ->
          reject(operation, "invalid_rate_plan")

        true ->
          apply_open_group(operation, attrs)
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_open_group(operation, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    rooms =
      Enum.map(attrs.rooms, fn room ->
        lodging = room.nightly_rate_cents * nights

        %{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          lodging_cents: lodging,
          deposit_due_cents: room_deposit(lodging, attrs.rate_plan)
        }
      end)

    lodging_total = Enum.sum(Enum.map(rooms, & &1.lodging_cents))
    deposit_due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

    group =
      %Group{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        booked_on: attrs.booked_on,
        arrival_on: attrs.arrival_on,
        departure_on: attrs.departure_on,
        rate_plan: attrs.rate_plan,
        policy_version: policy_version_for(attrs.rate_plan, attrs.booked_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      }
      |> Repo.insert!()

    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      %Room{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position,
        deposit_due_cents: room.deposit_due_cents
      }
      |> Repo.insert!()
    end)

    apply_result(operation, %{
      group_id: group.group_id,
      deposit_due_cents: group.deposit_due_cents,
      revision: group.revision
    })
  end

  defp room_deposit(lodging_cents, "flexible"),
    do: Money.percent(lodging_cents, @flexible_deposit_percent)

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  # --- Cancellation policy ---------------------------------------------------

  # A group's policy version is fixed when it is opened, from its booking
  # date and rate plan. Rescheduling never moves it to a newer policy.
  defp policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp window_days("flex-14"), do: 14
  defp window_days("flex-30"), do: 30
  defp window_days(_other), do: nil

  # Cancellation on the refundable_until date itself is refundable.
  defp refundable_until(group) do
    case window_days(group.policy_version) do
      nil -> nil
      days -> group.arrival_on |> Date.add(-days) |> Date.to_string()
    end
  end

  # --- record_cash_payment --------------------------------------------------

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      with_group(operation, group_id, fn group ->
        outstanding = group.deposit_due_cents - group.deposit_paid_cents

        cond do
          group.status != "active" ->
            reject(operation, "group_not_active")

          not usable_amount?(amount) ->
            reject(operation, "invalid_amount")

          amount > outstanding ->
            reject(operation, "payment_exceeds_outstanding")

          true ->
            apply_payment(operation, group, amount)
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_payment(operation, group, amount) do
    operation_id = Map.get(operation, "operation_id")

    # Cash fills the active rooms' deposits in the rooms' original order.
    allocate_cash(group, amount, operation_id)

    if is_binary(operation_id) do
      %PaymentDisposition{operation_id: operation_id} |> Repo.insert!()
    end

    record_movements(operation, [{:cash, "received", group.property_id, amount}])

    group
    |> Ecto.Changeset.change(%{
      cash_paid_cents: group.cash_paid_cents + amount,
      deposit_paid_cents: group.deposit_paid_cents + amount,
      revision: group.revision + 1
    })
    |> Repo.update!()

    apply_result(operation, %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents - amount,
      revision: group.revision + 1
    })
  end

  # --- reschedule_group -----------------------------------------------------

  defp reschedule_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on", "invalid_stay") do
      with_group(operation, group_id, fn group ->
        cond do
          group.status != "active" ->
            reject(operation, "group_not_active")

          Date.compare(new_arrival_on, occurred_on) != :gt ->
            reject(operation, "invalid_stay")

          true ->
            apply_reschedule(operation, group, new_arrival_on)
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_reschedule(operation, group, new_arrival_on) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    new_departure_on = Date.add(new_arrival_on, nights)

    group
    |> Ecto.Changeset.change(%{
      arrival_on: new_arrival_on,
      departure_on: new_departure_on,
      revision: group.revision + 1
    })
    |> Repo.update!()

    apply_result(operation, %{
      group_id: group.group_id,
      new_arrival_on: Date.to_string(new_arrival_on),
      new_departure_on: Date.to_string(new_departure_on),
      policy_version: group.policy_version,
      refundable_until: refundable_until(%{group | arrival_on: new_arrival_on}),
      revision: group.revision + 1
    })
  end

  # --- Cancellation (whole group or selected rooms) --------------------------

  defp cancel_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation") do
      with_group(operation, group_id, fn group ->
        if group.status != "active" do
          reject(operation, "group_not_active")
        else
          case refund_method(operation) do
            {:ok, method} -> apply_cancel_group(operation, group, occurred_on, method)
            :error -> reject(operation, "invalid_operation")
          end
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  # `cancel_group` settles the group's remaining active rooms and follows its
  # established result contract.
  defp apply_cancel_group(operation, group, occurred_on, refund_method) do
    case settle(operation, group, active_rooms(group.id), occurred_on, refund_method) do
      {:ok, refunded, retained, issued} ->
        apply_result(operation, %{
          group_id: group.group_id,
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: issued,
          revision: group.revision + 1
        })

      :error ->
        reject(operation, "refund_method_not_available")
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, room_ids} <- required_room_ids(operation) do
      with_group(operation, group_id, fn group ->
        rooms = active_rooms(group.id)

        cond do
          group.status != "active" ->
            reject(operation, "group_not_active")

          not valid_room_selection?(rooms, room_ids) ->
            reject(operation, "invalid_rooms")

          true ->
            case refund_method(operation) do
              {:ok, method} ->
                apply_cancel_rooms(operation, group, rooms, room_ids, occurred_on, method)

              :error ->
                reject(operation, "invalid_operation")
            end
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_cancel_rooms(operation, group, rooms, room_ids, occurred_on, refund_method) do
    # `rooms` is in the group's original room order, so the reported
    # cancelled rooms are too, regardless of the order the caller supplied.
    selected = Enum.filter(rooms, &(&1.room_id in room_ids))

    case settle(operation, group, selected, occurred_on, refund_method) do
      {:ok, refunded, retained, issued} ->
        apply_result(operation, %{
          group_id: group.group_id,
          cancelled_room_ids: Enum.map(selected, & &1.room_id),
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: issued,
          revision: group.revision + 1
        })

      :error ->
        reject(operation, "refund_method_not_available")
    end
  end

  # All selected room identifiers must name distinct, active rooms of the
  # group; anything else rejects the complete operation.
  defp valid_room_selection?(rooms, room_ids) do
    room_ids != [] and
      Enum.all?(room_ids, &is_binary/1) and
      length(Enum.uniq(room_ids)) == length(room_ids) and
      Enum.all?(room_ids, fn room_id -> Enum.any?(rooms, &(&1.room_id == room_id)) end)
  end

  defp required_room_ids(operation) do
    case Map.get(operation, "room_ids") do
      ids when is_list(ids) -> {:ok, ids}
      _other -> {:error, "invalid_operation"}
    end
  end

  # `refund_method` is optional; omitting it means cash.
  defp refund_method(operation) do
    case Map.get(operation, "refund_method") do
      nil -> {:ok, "cash"}
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _other -> :error
    end
  end

  # Settles the given active rooms with the group's fixed policy. Returns
  # {:ok, refunded, retained, issued} or :error when hotel credit was
  # requested for a non-refundable settlement.
  defp settle(operation, group, rooms, occurred_on, refund_method) do
    window = window_days(group.policy_version)
    refundable? = window != nil and Date.diff(group.arrival_on, occurred_on) >= window

    if refund_method == "hotel_credit" and not refundable? do
      # Hotel credit is not a way around a non-refundable policy.
      :error
    else
      {refunded, retained, issued} =
        settle_rooms!(operation, group, rooms, occurred_on, refund_method, refundable?)

      {:ok, refunded, retained, issued}
    end
  end

  defp settle_rooms!(operation, group, rooms, occurred_on, refund_method, refundable?) do
    allocations = room_allocations(rooms)
    applications = room_applications(rooms)

    cash = Enum.sum(Enum.map(allocations, & &1.amount_cents))
    credit = Enum.sum(Enum.map(applications, & &1.amount_cents))

    {refunded, retained, converted, issued, bucket} =
      cond do
        refundable? and refund_method == "hotel_credit" ->
          {0, 0, cash, bonus_value(cash), :converted_cents}

        refundable? ->
          {cash, 0, 0, 0, :refunded_cents}

        true ->
          {0, cash, 0, 0, :retained_cents}
      end

    settle_cash!(allocations, group.property_id, bucket)

    absorbed_or_consumed =
      if refundable? do
        # Applied credit returns to its original lots with its original
        # expiry; any amount absorbed by a shortfall is reported.
        {:absorbed, Enum.sum(Enum.map(applications, &restore_application!/1))}
      else
        # Applied credit is consumed by a non-refundable cancellation.
        Enum.each(applications, &Repo.delete!/1)
        {:consumed, credit}
      end

    if issued > 0 do
      issue_lot!(operation, group, allocations, issued, occurred_on)
    end

    settle_room_rows!(rooms)
    settle_group_totals!(group, rooms, cash, credit, refunded, retained, converted)

    credit_movement =
      case absorbed_or_consumed do
        {:absorbed, amount} -> {:credit, "absorbed", nil, amount}
        {:consumed, amount} -> {:credit, "consumed", nil, amount}
      end

    movements = [
      {:cash, settle_kind(bucket), group.property_id, cash},
      {:credit, "issued", nil, issued},
      credit_movement
    ]

    record_movements(operation, movements)

    {refunded, retained, issued}
  end

  # The held cash on the settled rooms moves to the settlement bucket, both
  # at group level and per funding payment, and the property it settles at is
  # remembered in the disposition's settled locations so a later chargeback
  # reclassifies it at that property. Allocations without a durable operation
  # identity are settled but attributed to nobody.
  defp settle_cash!(allocations, property, bucket) do
    allocations
    |> Enum.group_by(& &1.operation_id)
    |> Enum.each(fn
      {nil, _allocs} ->
        :ok

      {operation_id, allocs} ->
        amount = Enum.sum(Enum.map(allocs, & &1.amount_cents))

        bump_disposition!(operation_id, bucket, amount, property)
    end)

    Enum.each(allocations, &Repo.delete!/1)
  end

  defp bump_disposition!(operation_id, bucket, amount, property) do
    %PaymentDisposition{} =
      disposition =
      Repo.get_by(PaymentDisposition, operation_id: operation_id)

    location_key = location_key(bucket)

    locations =
      (disposition.settled_locations || %{})
      |> Map.update(location_key, %{property => amount}, fn props ->
        Map.update(props, property, amount, &(&1 + amount))
      end)

    disposition
    |> Ecto.Changeset.change([
      {bucket, Map.fetch!(disposition, bucket) + amount},
      {:settled_locations, locations}
    ])
    |> Repo.update!()
  end

  # Restored credit first extinguishes the lot's unrecovered clawback; only
  # the excess becomes available (or expires under the usual read-time
  # rules). Returns the absorbed amount so the settlement can report it.
  defp restore_application!(application) do
    Repo.delete!(application)

    lot = Repo.get!(CreditLot, application.lot_id)
    absorbed = min(application.amount_cents, lot.unrecovered_clawback_cents)

    lot
    |> Ecto.Changeset.change(%{
      available_cents: lot.available_cents + application.amount_cents - absorbed,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
    })
    |> Repo.update!()

    absorbed
  end

  # A refundable hotel-credit settlement issues one lot for the selected
  # rooms' combined cash, with the 10% bonus computed once on that total.
  defp issue_lot!(operation, group, allocations, issued, occurred_on) do
    lot =
      %CreditLot{
        guest_id: group.guest_id,
        source_operation_id: Map.get(operation, "operation_id"),
        available_cents: issued,
        expires_on: Date.add(occurred_on, @credit_lifetime_days)
      }
      |> Repo.insert!()

    allocations
    |> funding_sources()
    |> entitlements()
    |> Enum.each(fn {operation_id, amount} ->
      if amount > 0 do
        %CreditEntitlement{lot_id: lot.id, operation_id: operation_id, amount_cents: amount}
        |> Repo.insert!()
      end
    end)
  end

  # The settled cash sources in room-accounting funding order: the
  # unattributed senior block first, then operations in their fill order.
  defp funding_sources(allocations) do
    allocations
    |> Enum.group_by(& &1.operation_id)
    |> Enum.map(fn {operation_id, allocs} ->
      amounts = Enum.map(allocs, & &1.amount_cents)
      {operation_id, Enum.sum(amounts), Enum.min(Enum.map(allocs, & &1.seq))}
    end)
    |> Enum.sort_by(fn {operation_id, _amount, first_id} ->
      {if(is_nil(operation_id), do: 0, else: 1), first_id}
    end)
    |> Enum.map(fn {operation_id, amount, _first_id} -> {operation_id, amount} end)
  end

  # Each source's entitlement is the 10%-bonus value of settled cash through
  # that source minus the bonus value through the preceding one, with the
  # standard half-up rounding on both running totals. The entitlements
  # telescope exactly to the issued lot.
  defp entitlements(sources) do
    {entitlements, _settled} =
      Enum.map_reduce(sources, 0, fn {operation_id, amount}, running ->
        through = running + amount
        {{operation_id, bonus_value(through) - bonus_value(running)}, through}
      end)

    entitlements
  end

  defp bonus_value(cash_cents), do: cash_cents + Money.percent(cash_cents, @credit_bonus_percent)

  defp settle_room_rows!(rooms) do
    Enum.each(rooms, fn room ->
      room
      |> Ecto.Changeset.change(status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0)
      |> Repo.update!()
    end)
  end

  # Group totals describe active rooms only: the settled rooms' amounts leave
  # the lodging, due, and paid totals, and the settled cash lands in the
  # refunded, retained, or converted buckets.
  defp settle_group_totals!(group, rooms, cash, credit, refunded, retained, converted) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    lodging = Enum.sum(Enum.map(rooms, fn room -> room.nightly_rate_cents * nights end))
    due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))
    status = if active_room_count(group.id) == 0, do: "cancelled", else: group.status

    group
    |> Ecto.Changeset.change(%{
      status: status,
      lodging_total_cents: group.lodging_total_cents - lodging,
      deposit_due_cents: group.deposit_due_cents - due,
      deposit_paid_cents: group.deposit_paid_cents - cash - credit,
      cash_paid_cents: group.cash_paid_cents - cash,
      credit_paid_cents: group.credit_paid_cents - credit,
      refunded_cents: (group.refunded_cents || 0) + refunded,
      retained_cents: (group.retained_cents || 0) + retained,
      converted_cents: group.converted_cents + converted,
      revision: group.revision + 1
    })
    |> Repo.update!()
  end

  # --- apply_hotel_credit ----------------------------------------------------

  defp apply_hotel_credit(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      with_group(operation, group_id, fn group ->
        outstanding = group.deposit_due_cents - group.deposit_paid_cents

        cond do
          group.status != "active" ->
            reject(operation, "group_not_active")

          not usable_amount?(amount) ->
            reject(operation, "invalid_amount")

          amount > outstanding ->
            reject(operation, "payment_exceeds_outstanding")

          true ->
            apply_credit(operation, group, occurred_on, amount)
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_credit(operation, group, occurred_on, amount) do
    lots = available_lots(group.guest_id, occurred_on)
    available = Enum.sum(Enum.map(lots, & &1.available_cents))

    if available < amount do
      reject(operation, "insufficient_credit")
    else
      consume_lots(lots, group, amount)

      group
      |> Ecto.Changeset.change(%{
        credit_paid_cents: group.credit_paid_cents + amount,
        deposit_paid_cents: group.deposit_paid_cents + amount,
        revision: group.revision + 1
      })
      |> Repo.update!()

      apply_result(operation, %{
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents - amount,
        revision: group.revision + 1
      })
    end
  end

  # Consume lots by earliest expiry, then by source_operation_id, filling the
  # active rooms' deposits in the rooms' original order.
  defp consume_lots(lots, group, amount) do
    {state, _remaining} =
      Enum.reduce(lots, {room_state(group.id), amount}, fn lot, {state, remaining} ->
        if remaining <= 0 do
          {state, remaining}
        else
          take = min(lot.available_cents, remaining)

          lot
          |> Ecto.Changeset.change(available_cents: lot.available_cents - take)
          |> Repo.update!()

          {taken, state} = take_from_rooms(state, take, :credit)

          Enum.each(taken, fn {room, room_take} ->
            insert_allocation!(group, :credit, lot.id, room, room_take)
          end)

          {state, remaining - take}
        end
      end)

    persist_rooms(state)
  end

  # --- reduce_cash_payment ---------------------------------------------------

  defp reduce_cash_payment(operation) do
    with {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id"),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil -> reject(operation, "operation_not_found")
        record -> reduce_against_record(operation, record, amount)
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp reduce_against_record(operation, record, amount) do
    if applied_cash_payment?(record) do
      group = payment_group(record)

      case revision_ok?(group, operation) do
        :ok ->
          held = held_cash(record.operation_id)

          cond do
            held == 0 ->
              reject(operation, "payment_not_reducible", %{group_id: group.group_id})

            not usable_amount?(amount) ->
              reject(operation, "invalid_amount", %{group_id: group.group_id})

            amount > held ->
              reject(operation, "reduction_exceeds_held_cash", %{group_id: group.group_id})

            true ->
              apply_reduction(operation, record, group, amount)
          end

        rejected ->
          rejected
      end
    else
      reject(operation, "payment_not_reducible")
    end
  end

  defp apply_reduction(operation, record, group, amount) do
    # Remove held allocations belonging to the payment in reverse creation
    # order; they may currently fund rooms of any group after transfers.
    allocations = payment_allocations(record.operation_id)
    removed = remove_allocations(allocations, amount)

    %PaymentDisposition{} =
      disposition =
      Repo.get_by(PaymentDisposition, operation_id: record.operation_id)

    disposition
    |> Ecto.Changeset.change(reduced_cents: disposition.reduced_cents + amount)
    |> Repo.update!()

    adjust_removed_groups(removed, group)
    record_movements(operation, property_movements(removed, "reduced"))

    # The settled-history bookkeeping for a reduction belongs to the
    # addressed (original payment) group.
    final = Repo.get!(Group, group.id)

    final
    |> Ecto.Changeset.change(reduced_cents: final.reduced_cents + amount)
    |> Repo.update!()

    final = Repo.get!(Group, group.id)

    apply_result(operation, %{
      payment_operation_id: record.operation_id,
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: final.deposit_due_cents - final.deposit_paid_cents,
      revision: final.revision
    })
  end

  # --- charge_back_payment ---------------------------------------------------

  defp charge_back_payment(operation) do
    with {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id") do
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil -> reject(operation, "operation_not_found")
        record -> charge_back_record(operation, record)
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp charge_back_record(operation, record) do
    if applied_cash_payment?(record) do
      group = payment_group(record)

      case revision_ok?(group, operation) do
        :ok ->
          %PaymentDisposition{} =
            disposition =
            Repo.get_by(PaymentDisposition, operation_id: record.operation_id)

          chargeable = recorded_amount(record) - disposition.reduced_cents

          # A payment can be charged back whether its group is active or
          # cancelled, but never twice, and never once fully reduced.
          if chargeable <= 0 or disposition.charged_back_cents > 0 do
            reject(operation, "payment_not_chargeable", %{group_id: group.group_id})
          else
            apply_charge_back(operation, record, group, disposition, chargeable)
          end

        rejected ->
          rejected
      end
    else
      reject(operation, "payment_not_chargeable")
    end
  end

  defp apply_charge_back(operation, record, group, disposition, chargeable) do
    # Remove held allocations in reverse creation order, reopening the
    # affected groups' outstanding deposits wherever they currently fund
    # rooms.
    allocations = payment_allocations(record.operation_id)
    held = Enum.sum(Enum.map(allocations, & &1.amount_cents))
    removed = remove_allocations(allocations, held)

    # Refunded, retained, and converted principal reclassify as charged back;
    # the historical refund or retention itself is not reversed or reissued.
    # The property where each bucket settled comes from the settled locations.
    reversal_kinds = [
      {:refunded_cents, "refunded"},
      {:retained_cents, "retained"},
      {:converted_cents, "converted"}
    ]

    reversal_movements =
      Enum.flat_map(reversal_kinds, fn {field, kind} ->
        amount = Map.fetch!(disposition, field)
        locations = Map.get(disposition.settled_locations || %{}, kind, %{})

        reversal_movements(kind, group.property_id, amount, locations)
      end)

    disposition
    |> Ecto.Changeset.change(%{
      refunded_cents: 0,
      retained_cents: 0,
      converted_cents: 0,
      charged_back_cents: disposition.charged_back_cents + chargeable,
      settled_locations: %{}
    })
    |> Repo.update!()

    revoked = revoke_entitlements!(record.operation_id)

    adjust_removed_groups(removed, group)

    record_movements(
      operation,
      property_movements(removed, "charged_back") ++
        reversal_movements ++ [{:credit, "revoked", nil, revoked}]
    )

    # The settled-history buckets belong to the addressed original payment
    # group; it has already moved its revision exactly once.
    final = Repo.get!(Group, group.id)

    final
    |> Ecto.Changeset.change(%{
      refunded_cents: (final.refunded_cents || 0) - disposition.refunded_cents,
      retained_cents: (final.retained_cents || 0) - disposition.retained_cents,
      converted_cents: final.converted_cents - disposition.converted_cents,
      charged_back_cents: final.charged_back_cents + chargeable
    })
    |> Repo.update!()

    final = Repo.get!(Group, group.id)

    apply_result(operation, %{
      payment_operation_id: record.operation_id,
      group_id: group.group_id,
      charged_back_cents: chargeable,
      outstanding_deposit_cents: final.deposit_due_cents - final.deposit_paid_cents,
      revision: final.revision
    })
  end

  # A clawback removes the payment's entitlement from each lot's remaining
  # available balance first; whatever cannot be removed becomes that lot's
  # unrecovered clawback. Returns the removed total so the chargeback can
  # report the revoked liability.
  defp revoke_entitlements!(operation_id) do
    CreditEntitlement
    |> where([e], e.operation_id == ^operation_id)
    |> Repo.all()
    |> Enum.reduce(0, fn entitlement, removed_total ->
      lot = Repo.get!(CreditLot, entitlement.lot_id)
      removed = min(entitlement.amount_cents, lot.available_cents)

      lot
      |> Ecto.Changeset.change(%{
        available_cents: lot.available_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
      })
      |> Repo.update!()

      Repo.delete!(entitlement)

      removed_total + removed
    end)
  end

  # --- transfer_deposit ------------------------------------------------------

  # Moves held funding (cash and hotel credit allocated to active rooms)
  # between two active groups of the same guest without moving money through
  # a provider. Only the active rooms' held allocations change; no ledger
  # total moves.
  defp transfer_deposit(operation) do
    with {:ok, source_group_id} <- required_string(operation, "source_group_id"),
         {:ok, destination_group_id} <- required_string(operation, "destination_group_id"),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      # Resolve source existence, then destination existence.
      case Repo.get_by(Group, group_id: source_group_id) do
        nil ->
          reject(operation, "group_not_found", %{group_id: source_group_id})

        source ->
          case Repo.get_by(Group, group_id: destination_group_id) do
            nil ->
              reject(operation, "group_not_found", %{group_id: destination_group_id})

            destination ->
              # After both groups exist, check the source revision and then
              # the destination revision before the transfer rules.
              with :ok <- revision_guard(source, operation, "expected_revision"),
                   :ok <-
                     revision_guard(destination, operation, "destination_expected_revision") do
                transfer_groups(operation, source, destination, amount)
              else
                {:rejected, _result} = rejected -> rejected
              end
          end
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp revision_guard(group, operation, field) do
    case Map.get(operation, field) do
      nil ->
        :ok

      expected when is_integer(expected) ->
        if expected == group.revision, do: :ok, else: stale_revision(operation, group, expected)

      _other ->
        reject(operation, "invalid_operation")
    end
  end

  defp transfer_groups(operation, source, destination, amount) do
    held = source.cash_paid_cents + source.credit_paid_cents
    outstanding = destination.deposit_due_cents - destination.deposit_paid_cents

    cond do
      source.guest_id != destination.guest_id or source.id == destination.id ->
        reject(operation, "invalid_transfer")

      source.status != "active" ->
        reject(operation, "group_not_active", %{group_id: source.group_id})

      destination.status != "active" ->
        reject(operation, "group_not_active", %{group_id: destination.group_id})

      not usable_amount?(amount) ->
        reject(operation, "invalid_amount")

      amount > held ->
        reject(operation, "transfer_exceeds_held_funding")

      amount > outstanding ->
        reject(operation, "transfer_exceeds_outstanding")

      true ->
        apply_transfer(operation, source, destination, amount)
    end
  end

  defp apply_transfer(operation, source, destination, amount) do
    # Draw from the source's active-room allocations in reverse creation
    # order (most recently created first), regardless of funding kind.
    units = draw_units(source, amount)
    {cash_drawn, credit_drawn} = drawn_totals(units)

    # Fill the destination's active rooms in their original order,
    # preserving the drawn units' order and provenance.
    fill_units(destination, units)

    source
    |> Ecto.Changeset.change(%{
      cash_paid_cents: source.cash_paid_cents - cash_drawn,
      credit_paid_cents: source.credit_paid_cents - credit_drawn,
      deposit_paid_cents: source.deposit_paid_cents - amount,
      revision: source.revision + 1
    })
    |> Repo.update!()

    destination
    |> Ecto.Changeset.change(%{
      cash_paid_cents: destination.cash_paid_cents + cash_drawn,
      credit_paid_cents: destination.credit_paid_cents + credit_drawn,
      deposit_paid_cents: destination.deposit_paid_cents + amount,
      revision: destination.revision + 1
    })
    |> Repo.update!()

    record_movements(operation, [
      {:cash, "transferred_out", source.property_id, cash_drawn},
      {:cash, "transferred_in", destination.property_id, cash_drawn}
    ])

    apply_result(operation, %{
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents:
        source.deposit_due_cents - source.deposit_paid_cents + amount,
      destination_outstanding_deposit_cents:
        destination.deposit_due_cents - destination.deposit_paid_cents - amount,
      source_revision: source.revision + 1,
      destination_revision: destination.revision + 1
    })
  end

  # The drawn units, in draw order: {:cash, operation_id, amount} or
  # {:credit, lot_id, amount}. Each keeps its provenance: cash keeps its
  # payment operation identity and credit keeps its original lot.
  defp draw_units(group, amount) do
    rows =
      Enum.map(group_allocations(group.id, CashAllocation), &{:cash, &1}) ++
        Enum.map(group_allocations(group.id, CreditApplication), &{:credit, &1})

    {units, _left} =
      rows
      |> Enum.sort_by(fn {_kind, row} -> row.seq end, :desc)
      |> Enum.reduce({[], amount}, fn {kind, row}, {units, left} ->
        if left <= 0 do
          {units, left}
        else
          take = min(row.amount_cents, left)
          shave_source_row(kind, row, take)
          {[{kind, provenance(kind, row), take} | units], left - take}
        end
      end)

    Enum.reverse(units)
  end

  defp provenance(:cash, row), do: row.operation_id
  defp provenance(:credit, row), do: row.lot_id

  # Partially or fully consumes a held source allocation row and moves that
  # amount out of the room it sat on.
  defp shave_source_row(kind, row, take) do
    if take == row.amount_cents do
      Repo.delete!(row)
    else
      row
      |> Ecto.Changeset.change(amount_cents: row.amount_cents - take)
      |> Repo.update!()
    end

    room = Repo.get!(Room, row.room_id)
    field = if kind == :cash, do: :cash_paid_cents, else: :credit_paid_cents

    room
    |> Ecto.Changeset.change([{field, Map.fetch!(room, field) - take}])
    |> Repo.update!()
  end

  # Fills the drawn units into the destination's active rooms in original
  # room order, creating new allocation rows that keep the provenance, then
  # flags the funding payments that participated per unit.
  defp fill_units(group, units) do
    state =
      Enum.reduce(units, room_state(group.id), fn {kind, provenance, amount}, state ->
        {taken, state} = take_from_rooms(state, amount, kind)

        Enum.each(taken, fn {room, take} ->
          insert_allocation!(group, kind, provenance, room, take)
        end)

        state
      end)

    persist_rooms(state)

    units
    |> Enum.filter(fn {kind, provenance, _amount} -> kind == :cash and is_binary(provenance) end)
    |> Enum.map(fn {:cash, operation_id, _amount} -> operation_id end)
    |> Enum.uniq()
    |> Enum.each(fn operation_id ->
      case Repo.get_by(PaymentDisposition, operation_id: operation_id) do
        nil ->
          :ok

        disposition ->
          disposition
          |> Ecto.Changeset.change(transferred: true)
          |> Repo.update!()
      end
    end)
  end

  defp insert_allocation!(group, kind, provenance, room, amount) do
    seq = next_alloc_seq()

    case kind do
      :cash ->
        %CashAllocation{
          group_id: group.id,
          room_id: room.id,
          operation_id: provenance,
          amount_cents: amount,
          seq: seq
        }

      :credit ->
        %CreditApplication{
          lot_id: provenance,
          group_id: group.id,
          room_id: room.id,
          amount_cents: amount,
          seq: seq
        }
    end
    |> Repo.insert!()

    seq
  end

  defp drawn_totals(units) do
    Enum.reduce(units, {0, 0}, fn
      {:cash, _, amount}, {cash, credit} -> {cash + amount, credit}
      {:credit, _, amount}, {cash, credit} -> {cash, credit + amount}
    end)
  end

  defp group_allocations(group_id, kind) do
    kind
    |> where([a], a.group_id == ^group_id)
    |> Repo.all()
  end

  # The shared allocation sequence numbers new rows across both allocation
  # tables so deposits transferring either funding kind draw in one creation
  # order.
  defp next_alloc_seq do
    cash = Repo.one(from a in CashAllocation, select: coalesce(max(a.seq), 0))
    credit = Repo.one(from a in CreditApplication, select: coalesce(max(a.seq), 0))

    max(cash, credit) + 1
  end

  # --- Payment targeting helpers ----------------------------------------------

  defp applied_cash_payment?(record) do
    record.type == "record_cash_payment" and record.status == "applied"
  end

  # The addressed group is the original payment's group.
  defp payment_group(record) do
    Repo.get_by!(Group, group_id: Jason.decode!(record.result)["group_id"])
  end

  defp recorded_amount(record), do: Jason.decode!(record.result)["amount_cents"]

  # A payment's held allocations (wherever they currently fund rooms), in
  # reverse creation order.
  defp payment_allocations(operation_id) do
    CashAllocation
    |> where([a], a.operation_id == ^operation_id)
    |> order_by([a], desc: a.seq)
    |> Repo.all()
  end

  defp held_cash(operation_id) do
    CashAllocation
    |> where([a], a.operation_id == ^operation_id)
    |> select([a], coalesce(sum(a.amount_cents), 0))
    |> Repo.one()
  end

  # Removes `amount` cents of allocations (already in reverse creation
  # order), reopening each touched room's outstanding deposit. Returns the
  # per-group removed totals as `{group_fk, cents}` pairs so every group
  # whose state changed adjusts its totals and revision.
  defp remove_allocations(allocations, amount) do
    {removed, _left} =
      Enum.reduce(allocations, {[], amount}, fn row, {removed, left} ->
        if left <= 0 do
          {removed, left}
        else
          take = min(row.amount_cents, left)

          if take == row.amount_cents do
            Repo.delete!(row)
          else
            row
            |> Ecto.Changeset.change(amount_cents: row.amount_cents - take)
            |> Repo.update!()
          end

          room = Repo.get!(Room, row.room_id)

          room
          |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents - take)
          |> Repo.update!()

          {[{row.group_id, take} | removed], left - take}
        end
      end)

    removed
    |> Enum.group_by(fn {group_fk, _take} -> group_fk end, fn {_group_fk, take} -> take end)
    |> Enum.map(fn {group_fk, takes} -> {group_fk, Enum.sum(takes)} end)
  end

  # Adjusts the cash and paid totals of every group that lost held funding,
  # then increments the addressed group's revision exactly once (even when
  # none of its own allocations moved).
  defp adjust_removed_groups(removed, addressed_group) do
    Enum.each(removed, fn {group_fk, cents} ->
      group = Repo.get!(Group, group_fk)

      group
      |> Ecto.Changeset.change(%{
        cash_paid_cents: group.cash_paid_cents - cents,
        deposit_paid_cents: group.deposit_paid_cents - cents,
        revision: group.revision + 1
      })
      |> Repo.update!()
    end)

    unless Enum.any?(removed, fn {group_fk, _cents} -> group_fk == addressed_group.id end) do
      addressed_group
      |> Ecto.Changeset.change(revision: addressed_group.revision + 1)
      |> Repo.update!()
    end
  end

  # Builds cash movements named `kind`, grouped by the property of each
  # removed allocation's group (a correction follows the cash to the property
  # where it is held).
  defp property_movements(removed, kind) do
    group_ids = Enum.map(removed, fn {group_fk, _cents} -> group_fk end)

    properties =
      Group
      |> where([g], g.id in ^group_ids)
      |> select([g], {g.id, g.property_id})
      |> Repo.all()
      |> Map.new()

    removed
    |> Enum.group_by(
      fn {group_fk, _cents} -> Map.get(properties, group_fk) end,
      fn {_group_fk, cents} -> cents end
    )
    |> Enum.map(fn {property, amounts} ->
      {:cash, kind, property, Enum.sum(amounts)}
    end)
  end

  # The signed pair reclassifying one settled bucket as charged back: the
  # bucket's settled locations give the properties; anything without a
  # recorded location (settled before this release) falls back to the
  # original payment group's property.
  defp reversal_movements(kind, fallback_property, amount, locations) do
    locations = locations || %{}
    tracked = Enum.sum(Map.values(locations))
    remainder = amount - tracked

    location_pairs =
      Map.to_list(locations) ++
        if(remainder > 0, do: [{fallback_property, remainder}], else: [])

    Enum.flat_map(location_pairs, fn {property, part} ->
      [
        {:cash, movement_kind(kind), property, -part},
        {:cash, "charged_back", property, part}
      ]
    end)
  end

  defp movement_kind("refunded"), do: "refunded"
  defp movement_kind("retained"), do: "retained"
  defp movement_kind("converted"), do: "converted_to_credit"

  # --- Room-level funding ------------------------------------------------------

  defp active_rooms(group_id) do
    Room
    |> where([r], r.group_id == ^group_id and r.status == "active")
    |> order_by(:position)
    |> Repo.all()
  end

  defp active_room_count(group_id) do
    Room
    |> where([r], r.group_id == ^group_id and r.status == "active")
    |> select([r], count(r.id))
    |> Repo.one()
  end

  # The active rooms of a group with their current held funding, in the
  # rooms' original order.
  defp room_state(group_id) do
    group_id
    |> active_rooms()
    |> Enum.map(fn room ->
      %{room: room, cash: room.cash_paid_cents, credit: room.credit_paid_cents}
    end)
  end

  # Fills `amount` cents into the rooms in order, one room's remaining
  # deposit before the next. Returns the per-room takes and the new state.
  defp take_from_rooms(state, amount, kind) do
    {taken, _left, new_state} =
      Enum.reduce(state, {[], amount, []}, fn room_state, {taken, left, acc} ->
        outstanding =
          room_state.room.deposit_due_cents - room_state.cash - room_state.credit

        take = min(outstanding, max(left, 0))
        room_state = add_funding(room_state, kind, take)

        taken = if take > 0, do: [{room_state.room, take} | taken], else: taken
        {taken, left - take, [room_state | acc]}
      end)

    {Enum.reverse(taken), Enum.reverse(new_state)}
  end

  defp add_funding(room_state, :cash, take), do: %{room_state | cash: room_state.cash + take}

  defp add_funding(room_state, :credit, take),
    do: %{room_state | credit: room_state.credit + take}

  defp allocate_cash(group, amount, operation_id) do
    {taken, state} = take_from_rooms(room_state(group.id), amount, :cash)

    Enum.each(taken, fn {room, take} ->
      insert_allocation!(group, :cash, operation_id, room, take)
    end)

    persist_rooms(state)
  end

  defp persist_rooms(state) do
    Enum.each(state, fn room_state ->
      room = room_state.room

      if room_state.cash != room.cash_paid_cents or room_state.credit != room.credit_paid_cents do
        room
        |> Ecto.Changeset.change(%{
          cash_paid_cents: room_state.cash,
          credit_paid_cents: room_state.credit
        })
        |> Repo.update!()
      end
    end)
  end

  defp room_allocations(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    CashAllocation
    |> where([a], a.room_id in ^room_ids)
    |> order_by(:id)
    |> Repo.all()
  end

  defp room_applications(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    CreditApplication
    |> where([a], a.room_id in ^room_ids)
    |> Repo.all()
  end

  # --- Shared operation helpers ---------------------------------------------

  # Resolves an existing group for group-addressed operations, then enforces
  # the optional `expected_revision` precondition before running the domain
  # rule in `fun`.
  defp with_group(operation, group_id, fun) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        reject(operation, "group_not_found")

      group ->
        case revision_ok?(group, operation) do
          :ok -> fun.(group)
          {:rejected, _result} = rejected -> rejected
        end
    end
  end

  defp revision_ok?(group, operation) do
    case Map.get(operation, "expected_revision") do
      nil ->
        :ok

      expected when is_integer(expected) ->
        if expected == group.revision do
          :ok
        else
          stale_revision(operation, group, expected)
        end

      _other ->
        reject(operation, "invalid_operation")
    end
  end

  # --- Field extraction / validation ----------------------------------------

  defp required_string(operation, field) do
    case Map.get(operation, field) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, "invalid_operation"}
    end
  end

  defp required_value(operation, field) do
    case Map.get(operation, field) do
      nil -> {:error, "invalid_operation"}
      value -> {:ok, value}
    end
  end

  # Missing data makes the operation unidentifiable/unappliable
  # (invalid_operation); data that is present but unusable for the field gets
  # the field-specific code (e.g. invalid_stay for stay dates).
  defp required_date(operation, field, code) do
    case Map.get(operation, field) do
      nil ->
        {:error, "invalid_operation"}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, code}
        end

      _other ->
        {:error, code}
    end
  end

  defp required_rooms(operation) do
    case Map.get(operation, "rooms") do
      rooms when is_list(rooms) ->
        if Enum.all?(rooms, &valid_room?/1) do
          {:ok,
           Enum.map(rooms, fn room ->
             %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
           end)}
        else
          {:error, "invalid_rooms"}
        end

      _other ->
        {:error, "invalid_operation"}
    end
  end

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and is_integer(rate) and rate >= 0,
       do: true

  defp valid_room?(_other), do: false

  defp valid_rooms?(rooms) do
    rooms != [] and unique_room_ids?(rooms)
  end

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1.room_id)
    length(ids) == length(Enum.uniq(ids))
  end

  defp usable_amount?(amount), do: is_integer(amount) and amount > 0

  # --- Result builders -------------------------------------------------------

  defp apply_result(operation, extra) do
    {:applied,
     Map.merge(
       %{operation_id: Map.get(operation, "operation_id"), status: "applied"},
       extra
     )}
  end

  defp reject(operation, code, extra \\ %{}) do
    base = %{
      operation_id: get_in_map(operation, "operation_id"),
      status: "rejected",
      code: code,
      group_id: get_in_map(operation, "group_id")
    }

    {:rejected, Map.merge(base, extra)}
  end

  # The rejection map alone, for paths that return a result directly instead
  # of a tagged tuple.
  defp reject_result(operation, code) do
    {:rejected, result} = reject(operation, code)
    result
  end

  defp stale_revision(operation, group, expected) do
    {:rejected,
     %{
       operation_id: Map.get(operation, "operation_id"),
       status: "rejected",
       code: "stale_revision",
       group_id: group.group_id,
       expected_revision: expected,
       actual_revision: group.revision
     }}
  end

  defp get_in_map(operation, key) when is_map(operation), do: Map.get(operation, key)
  defp get_in_map(_operation, _key), do: nil

  # --- Reads -----------------------------------------------------------------

  @doc """
  Returns the stored result for a remembered operation id, or nil. The read
  endpoint exposes only the stored result, not the retained submission.
  """
  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> Jason.decode!(record.result)
    end
  end

  def get_operation(_operation_id), do: nil

  @doc """
  Returns the current disposition of cash from one durably recorded, applied
  cash payment: `nil` when no durable operation record exists, or
  `:not_reconcilable` when the record exists but is not an applied cash
  payment. The six disposition fields always sum to `recorded_cents`.

  Once any of the payment's cash participated in a deposit transfer, the
  statement adds `held_by_group`: the per-group held cash, ordered by group
  id, omitting groups with none. Earlier statements keep their shape.
  """
  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        nil

      %OperationRecord{type: "record_cash_payment", status: "applied"} = record ->
        disposition = Repo.get_by(PaymentDisposition, operation_id: record.operation_id)

        statement = %{
          payment_operation_id: record.operation_id,
          original_group_id: Jason.decode!(record.result)["group_id"],
          recorded_cents: recorded_amount(record),
          held_cents: held_cash(record.operation_id),
          refunded_cents: disposition_field(disposition, :refunded_cents),
          retained_cents: disposition_field(disposition, :retained_cents),
          converted_to_credit_cents: disposition_field(disposition, :converted_cents),
          reduced_cents: disposition_field(disposition, :reduced_cents),
          charged_back_cents: disposition_field(disposition, :charged_back_cents)
        }

        if disposition && disposition.transferred do
          Map.put(statement, :held_by_group, held_by_group(record.operation_id))
        else
          statement
        end

      %OperationRecord{} ->
        :not_reconcilable
    end
  end

  def get_payment(_payment_operation_id), do: nil

  # The groups currently holding the payment's cash, ordered by group id;
  # groups with no held cash are omitted, summing to held_cents.
  defp held_by_group(operation_id) do
    CashAllocation
    |> join(:inner, [a], g in Group, on: a.group_id == g.id)
    |> where([a], a.operation_id == ^operation_id)
    |> group_by([a, g], g.group_id)
    |> select([a, g], {g.group_id, sum(a.amount_cents)})
    |> Repo.all()
    |> Enum.map(fn {group_id, amount} -> %{group_id: group_id, amount_cents: amount} end)
    |> Enum.sort_by(& &1.group_id)
  end

  defp disposition_field(nil, _field), do: 0
  defp disposition_field(disposition, field), do: Map.fetch!(disposition, field)

  @doc "Fetches a group by its partner-supplied id, with rooms in order."
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  @doc "Serializes a group for the partner read endpoint."
  def group_view(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_string(group.booked_on),
      arrival_on: Date.to_string(group.arrival_on),
      departure_on: Date.to_string(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
    }
  end

  @doc "Returns the finance totals for the ledger endpoint as of `as_of`."
  def ledger_totals(as_of \\ Date.utc_today()) do
    %{
      cash_held_cents: sum_for_status("active", :cash_paid_cents),
      cash_refunded_cents: sum_all(:refunded_cents),
      cash_retained_cents: sum_all(:retained_cents),
      cash_converted_to_credit_cents: sum_all(:converted_cents),
      cash_reduced_cents: sum_all(:reduced_cents),
      cash_charged_back_cents: sum_all(:charged_back_cents),
      credit_liability_cents: credit_liability(as_of),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  # Credit liability covers both available credit and credit currently applied
  # to active groups (including credit covered by a current shortfall).
  # Expiry, non-refundable consumption, revoked unspent entitlement, and
  # shortfall absorption reduce it.
  @doc "Returns the credit liability (available plus applied to active) as of `as_of`."
  def credit_liability(as_of) do
    available =
      CreditLot
      |> where([l], l.available_cents > 0 and l.expires_on >= ^as_of)
      |> select([l], coalesce(sum(l.available_cents), 0))
      |> Repo.one()

    applied_to_active =
      CreditApplication
      |> join(:inner, [a], g in Group, on: a.group_id == g.id)
      |> where([a, g], g.status == "active")
      |> select([a, g], coalesce(sum(a.amount_cents), 0))
      |> Repo.one()

    available + applied_to_active
  end

  # A lot's current shortfall is the lesser of its unrecovered clawback and
  # the credit from that lot still applied to active groups.
  defp credit_shortfall do
    applied_per_lot =
      CreditApplication
      |> join(:inner, [a], g in Group, on: a.group_id == g.id and g.status == "active")
      |> group_by([a], a.lot_id)
      |> select([a], {a.lot_id, sum(a.amount_cents)})
      |> Repo.all()
      |> Map.new()

    CreditLot
    |> where([l], l.unrecovered_clawback_cents > 0)
    |> select([l], {l.id, l.unrecovered_clawback_cents})
    |> Repo.all()
    |> Enum.map(fn {lot_id, unrecovered} ->
      min(unrecovered, Map.get(applied_per_lot, lot_id, 0))
    end)
    |> Enum.sum()
  end

  @doc "Returns a guest's unexpired credit lots and their total as of `as_of`."
  def guest_credit(guest_id, as_of \\ Date.utc_today()) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.available_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.available_cents,
            expires_on: Date.to_string(lot.expires_on)
          }
        end)
    }
  end

  # Unexpired, non-exhausted lots for a guest, in consumption order: earliest
  # expiry first, then source_operation_id.
  defp available_lots(guest_id, as_of) do
    CreditLot
    |> where([l], l.guest_id == ^guest_id and l.available_cents > 0 and l.expires_on >= ^as_of)
    |> order_by([l], asc: l.expires_on, asc: l.source_operation_id)
    |> Repo.all()
  end

  defp sum_for_status(status, field) do
    Group
    |> where([g], g.status == ^status)
    |> select([g], coalesce(sum(field(g, ^field)), 0))
    |> Repo.one()
  end

  defp sum_all(field) do
    Group
    |> select([g], coalesce(sum(field(g, ^field)), 0))
    |> Repo.one()
  end
end
