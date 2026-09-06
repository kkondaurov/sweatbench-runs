defmodule GroupStay.Deposits do
  @moduledoc "Room-level group deposit accounting and durable partner operations."

  import Ecto.Query

  alias GroupStay.Deposits.{
    CashAllocation,
    CashPayment,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    PartnerOperation,
    Room
  }

  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @group_types ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms)
  @policy_change_on ~D[2027-01-01]
  @max_integer 9_223_372_036_854_775_807

  def submit_batch(operations) when is_list(operations),
    do: Enum.map(operations, &apply_operation/1)

  def get_group(id) when is_binary(id) do
    case Repo.get(Group, id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_), do: nil

  def get_operation_result(id) when is_binary(id) do
    case Repo.get_by(PartnerOperation, operation_id: id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_operation_result(_), do: nil

  def payment_statement(id) when is_binary(id) do
    case Repo.get_by(PartnerOperation, operation_id: id) do
      nil ->
        :not_found

      _ ->
        case Repo.get_by(CashPayment, operation_id: id) do
          nil -> :not_reconcilable
          payment -> {:ok, payment_data(payment)}
        end
    end
  end

  def payment_statement(_), do: :not_found

  def group_data(%Group{} = group) do
    cash = allocation_sums(CashAllocation, group.group_id)
    credit = allocation_sums(CreditAllocation, group.group_id)
    active = Enum.filter(group.rooms, &(&1.status == "active"))
    lodging = Enum.sum(Enum.map(active, & &1.lodging_total_cents))
    due = Enum.sum(Enum.map(active, & &1.deposit_due_cents))
    cash_paid = Enum.sum(Enum.map(active, &Map.get(cash, &1.id, 0)))
    credit_paid = Enum.sum(Enum.map(active, &Map.get(credit, &1.id, 0)))

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
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
            cash_paid_cents: Map.get(cash, room.id, 0),
            credit_paid_cents: Map.get(credit, room.id, 0)
          }
        end),
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      deposit_paid_cents: cash_paid + credit_paid,
      cash_paid_cents: cash_paid,
      credit_paid_cents: credit_paid,
      outstanding_deposit_cents: max(due - cash_paid - credit_paid, 0)
    }
  end

  def ledger(on \\ Date.utc_today()) do
    {:ok, data} = Repo.transaction(fn -> ledger_data(on) end)
    data
  end

  defp ledger_data(on) do
    held =
      Repo.one(
        from a in CashAllocation,
          join: r in Room,
          on: r.id == a.room_id,
          where: r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    history =
      Repo.one(
        from g in Group,
          select: %{
            refunded: coalesce(sum(g.cash_refunded_cents), 0),
            retained: coalesce(sum(g.cash_retained_cents), 0),
            converted: coalesce(sum(g.cash_converted_to_credit_cents), 0)
          }
      )

    payments =
      Repo.one(
        from p in CashPayment,
          select: %{
            reduced: coalesce(sum(p.reduced_cents), 0),
            charged_back: coalesce(sum(p.charged_back_cents), 0)
          }
      )

    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    %{
      cash_held_cents: held,
      cash_refunded_cents: history.refunded,
      cash_retained_cents: history.retained,
      cash_converted_to_credit_cents: history.converted,
      cash_reduced_cents: payments.reduced,
      cash_charged_back_cents: payments.charged_back,
      credit_liability_cents: available + active_applied_credit(),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(
          lots,
          &%{
            source_operation_id: &1.source_operation_id,
            remaining_cents: &1.remaining_cents,
            expires_on: &1.expires_on
          }
        )
    }
  end

  defp apply_operation(operation) when not is_map(operation),
    do: rejected(nil, "invalid_operation")

  defp apply_operation(operation) do
    operation = stringify_keys(operation)

    case operation do
      %{"operation_id" => id} when is_binary(id) and id != "" -> transact(operation)
      _ -> rejected(Map.get(operation, "operation_id"), "invalid_operation")
    end
  end

  defp transact(operation) do
    fun = fn ->
      case Repo.get_by(PartnerOperation, operation_id: operation["operation_id"]) do
        nil -> process_and_remember(operation)
        existing when existing.payload === operation -> existing.result
        _ -> rejected(operation["operation_id"], "operation_id_conflict")
      end
    end

    case Repo.transaction(fun, mode: :immediate) do
      {:ok, result} -> result
      {:error, :retry} -> transact(operation)
    end
  end

  defp process_and_remember(operation) do
    result =
      case process_operation(operation) do
        {:ok, result} -> result
        {:error, :retry} -> Repo.rollback(:retry)
        {:error, result} -> result
      end

    %PartnerOperation{}
    |> PartnerOperation.changeset(%{
      operation_id: operation["operation_id"],
      operation_type: submitted_type(operation),
      payload: operation,
      result: result
    })
    |> Repo.insert!()

    result
  end

  defp process_operation(%{"type" => type} = op) when is_binary(type), do: dispatch(op, type)
  defp process_operation(op), do: {:error, rejected(op["operation_id"], "invalid_operation")}
  defp dispatch(op, "open_group"), do: open_group(op)

  defp dispatch(op, type) when type in @group_types do
    case required_identifier(op, "group_id") do
      {:ok, id} -> apply_to_group(op, type, id)
      _ -> {:error, rejected(op["operation_id"], "invalid_operation")}
    end
  end

  defp dispatch(op, "reduce_cash_payment"), do: reduce_cash_payment(op)
  defp dispatch(op, "charge_back_payment"), do: charge_back_payment(op)
  defp dispatch(op, _), do: {:error, rejected(op["operation_id"], "invalid_operation")}
  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_), do: nil

  defp open_group(op) do
    required =
      ~w(occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    with true <- Enum.all?(required, &Map.has_key?(op, &1)),
         true <- identifiers_valid?(op, ~w(group_id guest_id property_id)) do
      if Repo.exists?(from g in Group, where: g.group_id == ^op["group_id"]),
        do: {:error, rejected(op, "group_already_exists", op["group_id"])},
        else: validate_and_insert_group(op)
    else
      _ -> {:error, rejected(op["operation_id"], "invalid_operation")}
    end
  end

  defp validate_and_insert_group(op) do
    with {:ok, booked} <- parse_date(op["occurred_on"]),
         {:ok, arrival} <- parse_date(op["arrival_on"]),
         {:ok, departure} <- parse_date(op["departure_on"]),
         true <- Date.compare(departure, arrival) == :gt do
      nights = Date.diff(departure, arrival)

      cond do
        op["rate_plan"] not in @rate_plans ->
          {:error, rejected(op, "invalid_rate_plan", op["group_id"])}

        not valid_rooms?(op["rooms"], nights) ->
          {:error, rejected(op, "invalid_rooms", op["group_id"])}

        true ->
          insert_group(op, booked, arrival, departure)
      end
    else
      _ -> {:error, rejected(op, "invalid_stay", op["group_id"])}
    end
  end

  defp insert_group(op, booked, arrival, departure) do
    nights = Date.diff(departure, arrival)
    lodging = Enum.map(op["rooms"], &(nights * &1["nightly_rate_cents"]))

    deposits =
      case op["rate_plan"] do
        "flexible" -> Enum.map(lodging, &round_percentage(&1, 20))
        "advance_purchase" -> lodging
      end

    attrs = %{
      group_id: op["group_id"],
      guest_id: op["guest_id"],
      property_id: op["property_id"],
      revision: 1,
      booked_on: booked,
      arrival_on: arrival,
      departure_on: departure,
      rate_plan: op["rate_plan"],
      policy_version: policy_version_for(op["rate_plan"], booked),
      status: "active",
      lodging_total_cents: Enum.sum(lodging),
      deposit_due_cents: Enum.sum(deposits),
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      cash_refunded_cents: 0,
      cash_retained_cents: 0,
      cash_converted_to_credit_cents: 0
    }

    case Repo.insert(Group.changeset(%Group{}, attrs)) do
      {:ok, group} ->
        insert_rooms!(group, op["rooms"], lodging, deposits)

        {:ok,
         applied(op, %{
           group_id: group.group_id,
           deposit_due_cents: group.deposit_due_cents,
           revision: group.revision
         })}

      {:error, _} ->
        {:error, rejected(op, "group_already_exists", op["group_id"])}
    end
  end

  defp insert_rooms!(group, rooms, lodging, deposits) do
    timestamp = now()

    entries =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          group_id: group.group_id,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"],
          position: position,
          status: "active",
          lodging_total_cents: Enum.at(lodging, position),
          deposit_due_cents: Enum.at(deposits, position),
          inserted_at: timestamp,
          updated_at: timestamp
        }
      end)

    {_count, nil} = Repo.insert_all(Room, entries)
  end

  defp apply_to_group(op, type, id) do
    case Repo.get(Group, id) do
      nil ->
        {:error, rejected(op, "group_not_found", id)}

      group ->
        with :ok <- validate_revision(op, group), :ok <- require_fields(op, type) do
          apply_group_operation(op, type, group)
        else
          {:error, :stale} -> {:error, stale_rejection(op, group)}
          _ -> {:error, rejected(op, "invalid_operation", id)}
        end
    end
  end

  defp validate_revision(op, group) do
    case Map.fetch(op, "expected_revision") do
      :error ->
        :ok

      {:ok, revision} when is_integer(revision) ->
        if revision == group.revision, do: :ok, else: {:error, :stale}

      _ ->
        {:error, :invalid}
    end
  end

  defp require_fields(op, type) when type in ~w(record_cash_payment apply_hotel_credit),
    do: require_present(op, ~w(occurred_on amount_cents))

  defp require_fields(op, "reschedule_group"),
    do: require_present(op, ~w(occurred_on new_arrival_on))

  defp require_fields(op, "cancel_group"), do: require_present(op, ~w(occurred_on))
  defp require_fields(op, "cancel_rooms"), do: require_present(op, ~w(occurred_on room_ids))

  defp require_present(op, keys),
    do: if(Enum.all?(keys, &Map.has_key?(op, &1)), do: :ok, else: {:error, :invalid})

  defp apply_group_operation(op, _, %{status: status} = group) when status != "active",
    do: {:error, rejected(op, "group_not_active", group.group_id)}

  defp apply_group_operation(op, "record_cash_payment", group) do
    amount = op["amount_cents"]

    cond do
      not valid_date?(op["occurred_on"]) ->
        {:error, rejected(op, "invalid_operation", group.group_id)}

      not positive?(amount) ->
        {:error, rejected(op, "invalid_amount", group.group_id)}

      amount > outstanding(group.group_id) ->
        {:error, rejected(op, "payment_exceeds_outstanding", group.group_id)}

      true ->
        payment =
          %CashPayment{}
          |> CashPayment.changeset(%{
            operation_id: op["operation_id"],
            group_id: group.group_id,
            recorded_cents: amount
          })
          |> Repo.insert!()

        allocate_cash(group.group_id, payment.id, amount)
        finish_update(op, group, &payment_result(&1, amount))
    end
  end

  defp apply_group_operation(op, "apply_hotel_credit", group) do
    amount = op["amount_cents"]

    with {:ok, occurred} <- parse_date(op["occurred_on"]) do
      cond do
        not positive?(amount) ->
          {:error, rejected(op, "invalid_amount", group.group_id)}

        amount > outstanding(group.group_id) ->
          {:error, rejected(op, "payment_exceeds_outstanding", group.group_id)}

        available_credit(group.guest_id, occurred) < amount ->
          {:error, rejected(op, "insufficient_credit", group.group_id)}

        true ->
          allocate_credit(group, amount, occurred)
          finish_update(op, group, &payment_result(&1, amount))
      end
    else
      _ -> {:error, rejected(op, "invalid_operation", group.group_id)}
    end
  end

  defp apply_group_operation(op, "reschedule_group", group) do
    with {:ok, occurred} <- parse_date(op["occurred_on"]),
         {:ok, arrival} <- parse_date(op["new_arrival_on"]),
         true <- Date.compare(arrival, occurred) == :gt do
      shift = Date.diff(arrival, group.arrival_on)

      update_group(
        op,
        group,
        %{arrival_on: arrival, departure_on: Date.add(group.departure_on, shift)},
        fn updated ->
          %{
            group_id: updated.group_id,
            new_arrival_on: updated.arrival_on,
            new_departure_on: updated.departure_on,
            policy_version: updated.policy_version,
            refundable_until: refundable_until(updated),
            revision: updated.revision
          }
        end
      )
    else
      _ -> {:error, rejected(op, "invalid_stay", group.group_id)}
    end
  end

  defp apply_group_operation(op, "cancel_group", group),
    do: cancel_selected(op, group, active_rooms(group.group_id), false)

  defp apply_group_operation(op, "cancel_rooms", group) do
    ids = op["room_ids"]
    rooms = active_rooms(group.group_id)
    active_ids = MapSet.new(rooms, & &1.room_id)

    valid =
      is_list(ids) and ids != [] and Enum.all?(ids, &is_binary/1) and
        Enum.uniq(ids) == ids and Enum.all?(ids, &MapSet.member?(active_ids, &1))

    if valid,
      do: cancel_selected(op, group, Enum.filter(rooms, &(&1.room_id in ids)), true),
      else: {:error, rejected(op, "invalid_rooms", group.group_id)}
  end

  defp cancel_selected(op, group, rooms, include_ids?) do
    method = Map.get(op, "refund_method", "cash")

    with {:ok, occurred} <- parse_date(op["occurred_on"]),
         true <- method in ~w(cash hotel_credit) do
      refundable = refundable_on?(group, occurred)

      if method == "hotel_credit" and not refundable,
        do: {:error, rejected(op, "refund_method_not_available", group.group_id)},
        else: settle_rooms(op, group, rooms, occurred, refundable, method, include_ids?)
    else
      _ -> {:error, rejected(op, "invalid_operation", group.group_id)}
    end
  end

  defp settle_rooms(op, group, rooms, occurred, refundable, method, include_ids?) do
    room_ids = Enum.map(rooms, & &1.id)
    allocations = cash_for_rooms(room_ids)
    cash = Enum.sum(Enum.map(allocations, & &1.amount_cents))

    disposition =
      cond do
        refundable and method == "cash" -> :refunded_cents
        refundable and method == "hotel_credit" -> :converted_cents
        true -> :retained_cents
      end

    classify_cash(allocations, disposition)
    if refundable, do: restore_credit(room_ids, occurred), else: consume_credit(room_ids)

    issued =
      if disposition == :converted_cents and cash > 0,
        do: issue_credit(op, group, allocations, occurred, cash),
        else: 0

    Repo.update_all(from(r in Room, where: r.id in ^room_ids),
      set: [status: "cancelled", updated_at: now()]
    )

    remaining =
      Repo.exists?(from r in Room, where: r.group_id == ^group.group_id and r.status == "active")

    refunded = if disposition == :refunded_cents, do: cash, else: 0
    retained = if disposition == :retained_cents, do: cash, else: 0
    converted = if disposition == :converted_cents, do: cash, else: 0

    attrs =
      sync_attrs(group.group_id)
      |> Map.merge(%{
        status: if(remaining, do: "active", else: "cancelled"),
        cash_refunded_cents: group.cash_refunded_cents + refunded,
        cash_retained_cents: group.cash_retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
      })

    update_group(op, group, attrs, fn updated ->
      result = %{
        group_id: updated.group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: issued,
        revision: updated.revision
      }

      if include_ids?,
        do: Map.put(result, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
        else: result
    end)
  end

  defp reduce_cash_payment(op) do
    with {:ok, target} <- required_identifier(op, "payment_operation_id"),
         {:ok, payment, group} <- target_payment(op, target, "payment_not_reducible"),
         :ok <- validate_revision(op, group),
         true <- Map.has_key?(op, "amount_cents") do
      amount = op["amount_cents"]
      held = held_for(payment.id)

      cond do
        held == 0 ->
          {:error, reject_payment(op, "payment_not_reducible", target, group.group_id)}

        not positive?(amount) ->
          {:error, reject_payment(op, "invalid_amount", target, group.group_id)}

        amount > held ->
          {:error, reject_payment(op, "reduction_exceeds_held_cash", target, group.group_id)}

        true ->
          remove_held(payment.id, amount)
          update_payment!(payment, %{reduced_cents: payment.reduced_cents + amount})

          finish_update(op, group, fn updated ->
            %{
              payment_operation_id: target,
              group_id: updated.group_id,
              amount_cents: amount,
              outstanding_deposit_cents: outstanding(updated.group_id),
              revision: updated.revision
            }
          end)
      end
    else
      :missing -> {:error, rejected(op["operation_id"], "invalid_operation")}
      false -> {:error, rejected(op["operation_id"], "invalid_operation")}
      {:error, :stale} -> stale_for_target(op)
      {:error, :invalid} -> {:error, rejected(op["operation_id"], "invalid_operation")}
      {:error, result} -> {:error, result}
    end
  end

  defp charge_back_payment(op) do
    with {:ok, target} <- required_identifier(op, "payment_operation_id"),
         {:ok, payment, group} <- target_payment(op, target, "payment_not_chargeable"),
         :ok <- validate_revision(op, group),
         true <-
           payment.charged_back_cents == 0 and payment.recorded_cents > payment.reduced_cents do
      amount = payment.recorded_cents - payment.reduced_cents
      remove_held(payment.id, held_for(payment.id))
      claw_back_entitlements(payment.id)

      attrs =
        sync_attrs(group.group_id)
        |> Map.merge(%{
          cash_refunded_cents: group.cash_refunded_cents - payment.refunded_cents,
          cash_retained_cents: group.cash_retained_cents - payment.retained_cents,
          cash_converted_to_credit_cents:
            group.cash_converted_to_credit_cents - payment.converted_cents
        })

      update_payment!(payment, %{
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0,
        charged_back_cents: amount
      })

      update_group(op, group, attrs, fn updated ->
        %{
          payment_operation_id: target,
          group_id: updated.group_id,
          charged_back_cents: amount,
          outstanding_deposit_cents: outstanding(updated.group_id),
          revision: updated.revision
        }
      end)
    else
      :missing -> {:error, rejected(op["operation_id"], "invalid_operation")}
      false -> {:error, reject_payment(op, "payment_not_chargeable", op["payment_operation_id"])}
      {:error, :stale} -> stale_for_target(op)
      {:error, :invalid} -> {:error, rejected(op["operation_id"], "invalid_operation")}
      {:error, result} -> {:error, result}
    end
  end

  defp target_payment(op, target, invalid_code) do
    case Repo.get_by(PartnerOperation, operation_id: target) do
      nil ->
        {:error, reject_payment(op, "operation_not_found", target)}

      _ ->
        case Repo.get_by(CashPayment, operation_id: target) do
          nil -> {:error, reject_payment(op, invalid_code, target)}
          payment -> {:ok, payment, Repo.get!(Group, payment.group_id)}
        end
    end
  end

  defp stale_for_target(op) do
    payment = Repo.get_by!(CashPayment, operation_id: op["payment_operation_id"])
    {:error, stale_rejection(op, Repo.get!(Group, payment.group_id))}
  end

  defp allocate_cash(group_id, payment_id, amount) do
    allocate_to_rooms(group_id, amount, fn room_id, used ->
      %CashAllocation{}
      |> CashAllocation.changeset(%{
        group_id: group_id,
        room_id: room_id,
        cash_payment_id: payment_id,
        amount_cents: used
      })
      |> Repo.insert!()
    end)
  end

  defp allocate_credit(group, amount, occurred) do
    lots =
      Repo.all(
        from l in CreditLot,
          where:
            l.guest_id == ^group.guest_id and l.remaining_cents > 0 and l.expires_on >= ^occurred,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    units = take_units(lots, amount, & &1.remaining_cents)

    Enum.each(units, fn {lot, used} ->
      update_lot!(lot, %{remaining_cents: lot.remaining_cents - used})
    end)

    allocate_units(group.group_id, units, fn room_id, lot, used ->
      %CreditAllocation{}
      |> CreditAllocation.changeset(%{
        group_id: group.group_id,
        room_id: room_id,
        credit_lot_id: lot.id,
        amount_cents: used
      })
      |> Repo.insert!()
    end)
  end

  defp allocate_to_rooms(group_id, amount, fun) do
    Enum.reduce_while(room_capacities(group_id), amount, fn {room, capacity}, remaining ->
      used = min(capacity, remaining)
      if used > 0, do: fun.(room.id, used)
      if used == remaining, do: {:halt, 0}, else: {:cont, remaining - used}
    end)
  end

  defp allocate_units(group_id, units, fun) do
    Enum.reduce(units, room_capacities(group_id), fn {unit, amount}, rooms ->
      {next, remaining} =
        Enum.map_reduce(rooms, amount, fn {room, capacity}, left ->
          used = min(capacity, left)
          if used > 0, do: fun.(room.id, unit, used)
          {{room, capacity - used}, left - used}
        end)

      if remaining != 0, do: raise("room allocation invariant failed")
      Enum.filter(next, fn {_, capacity} -> capacity > 0 end)
    end)
  end

  defp take_units(items, amount, fun) do
    {units, remaining} =
      Enum.reduce_while(items, {[], amount}, fn item, {acc, left} ->
        used = min(fun.(item), left)
        next = {[{item, used} | acc], left - used}
        if used == left, do: {:halt, next}, else: {:cont, next}
      end)

    if remaining != 0, do: raise("funding availability invariant failed")
    Enum.reverse(units)
  end

  defp room_capacities(group_id),
    do:
      active_rooms(group_id)
      |> Enum.map(&{&1, &1.deposit_due_cents - room_paid(&1.id)})
      |> Enum.filter(&(elem(&1, 1) > 0))

  defp cash_for_rooms(ids),
    do:
      Repo.all(
        from a in CashAllocation,
          left_join: p in CashPayment,
          on: p.id == a.cash_payment_id,
          where: a.room_id in ^ids,
          order_by: [asc_nulls_first: a.cash_payment_id, asc: p.id, asc: a.id]
      )

  defp classify_cash(allocations, field) do
    allocations
    |> Enum.group_by(& &1.cash_payment_id)
    |> Enum.each(fn
      {nil, rows} ->
        Enum.each(rows, &Repo.delete!/1)

      {payment_id, rows} ->
        payment = Repo.get!(CashPayment, payment_id)
        amount = Enum.sum(Enum.map(rows, & &1.amount_cents))
        update_payment!(payment, %{field => Map.fetch!(payment, field) + amount})
        Enum.each(rows, &Repo.delete!/1)
    end)
  end

  defp issue_credit(op, group, allocations, occurred, cash) do
    issued = cash + round_percentage(cash, 10)

    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: op["operation_id"],
        remaining_cents: issued,
        expires_on: Date.add(occurred, 365),
        unrecovered_clawback_cents: 0
      })
      |> Repo.insert!()

    contributions =
      allocations
      |> Enum.group_by(& &1.cash_payment_id)
      |> Enum.map(fn {id, rows} -> {id, Enum.sum(Enum.map(rows, & &1.amount_cents))} end)
      |> Enum.sort_by(fn {id, _} -> if id, do: {1, id}, else: {0, 0} end)

    Enum.reduce(contributions, {0, 0}, fn
      {nil, amount}, {principal, _previous} ->
        total = principal + amount
        {total, total + round_percentage(total, 10)}

      {payment_id, amount}, {principal, previous} ->
        total = principal + amount
        total_issued = total + round_percentage(total, 10)

        %CreditEntitlement{}
        |> CreditEntitlement.changeset(%{
          credit_lot_id: lot.id,
          cash_payment_id: payment_id,
          amount_cents: total_issued - previous
        })
        |> Repo.insert!()

        {total, total_issued}
    end)

    issued
  end

  defp restore_credit(room_ids, occurred) do
    Repo.all(
      from a in CreditAllocation,
        join: l in assoc(a, :lot),
        where: a.room_id in ^room_ids,
        order_by: a.id,
        preload: [lot: l]
    )
    |> Enum.each(fn allocation ->
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)
      absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)
      excess = allocation.amount_cents - absorbed

      remaining =
        if excess > 0 and Date.compare(lot.expires_on, occurred) in [:eq, :gt],
          do: lot.remaining_cents + excess,
          else: lot.remaining_cents

      update_lot!(lot, %{
        remaining_cents: remaining,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      })

      Repo.delete!(allocation)
    end)
  end

  defp consume_credit(ids),
    do: Repo.delete_all(from a in CreditAllocation, where: a.room_id in ^ids)

  defp remove_held(_, 0), do: :ok

  defp remove_held(payment_id, amount) do
    allocations =
      Repo.all(
        from a in CashAllocation,
          join: r in Room,
          on: r.id == a.room_id,
          where: a.cash_payment_id == ^payment_id and r.status == "active",
          order_by: [desc: r.position, desc: a.id]
      )

    Enum.reduce_while(allocations, amount, fn allocation, left ->
      removed = min(allocation.amount_cents, left)

      if removed == allocation.amount_cents,
        do: Repo.delete!(allocation),
        else:
          allocation
          |> CashAllocation.changeset(%{amount_cents: allocation.amount_cents - removed})
          |> Repo.update!()

      if removed == left, do: {:halt, 0}, else: {:cont, left - removed}
    end)

    :ok
  end

  defp claw_back_entitlements(payment_id) do
    Repo.all(from e in CreditEntitlement, where: e.cash_payment_id == ^payment_id)
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      revoked = min(lot.remaining_cents, entitlement.amount_cents)

      update_lot!(lot, %{
        remaining_cents: lot.remaining_cents - revoked,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - revoked
      })
    end)
  end

  defp finish_update(op, group, result),
    do: update_group(op, group, sync_attrs(group.group_id), result)

  defp sync_attrs(group_id) do
    rooms = active_rooms(group_id)
    cash = allocation_total(CashAllocation, group_id)
    credit = allocation_total(CreditAllocation, group_id)

    %{
      lodging_total_cents: Enum.sum(Enum.map(rooms, & &1.lodging_total_cents)),
      deposit_due_cents: Enum.sum(Enum.map(rooms, & &1.deposit_due_cents)),
      deposit_paid_cents: cash + credit,
      cash_paid_cents: cash,
      credit_paid_cents: credit
    }
  end

  defp update_group(op, group, attrs, result_fun) do
    {count, _} =
      Repo.update_all(
        from(g in Group, where: g.group_id == ^group.group_id and g.revision == ^group.revision),
        set: Keyword.put(Map.to_list(attrs), :updated_at, now()),
        inc: [revision: 1]
      )

    if count == 1 do
      updated = Repo.get!(Group, group.group_id)
      {:ok, applied(op, result_fun.(updated))}
    else
      if Map.has_key?(op, "expected_revision"),
        do: {:error, stale_rejection(op, Repo.get!(Group, group.group_id))},
        else: {:error, :retry}
    end
  end

  defp payment_result(group, amount),
    do: %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(group.group_id),
      revision: group.revision
    }

  defp payment_data(payment),
    do: %{
      payment_operation_id: payment.operation_id,
      original_group_id: payment.group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: held_for(payment.id),
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }

  defp active_rooms(group_id),
    do:
      Repo.all(
        from r in Room,
          where: r.group_id == ^group_id and r.status == "active",
          order_by: r.position
      )

  defp room_paid(id),
    do: allocation_room_total(CashAllocation, id) + allocation_room_total(CreditAllocation, id)

  defp allocation_room_total(schema, id),
    do:
      Repo.one(
        from a in schema, where: a.room_id == ^id, select: coalesce(sum(a.amount_cents), 0)
      )

  defp allocation_total(schema, id),
    do:
      Repo.one(
        from a in schema, where: a.group_id == ^id, select: coalesce(sum(a.amount_cents), 0)
      )

  defp allocation_sums(schema, id),
    do:
      Repo.all(
        from a in schema,
          where: a.group_id == ^id,
          group_by: a.room_id,
          select: {a.room_id, sum(a.amount_cents)}
      )
      |> Map.new()

  defp held_for(id),
    do:
      Repo.one(
        from a in CashAllocation,
          where: a.cash_payment_id == ^id,
          select: coalesce(sum(a.amount_cents), 0)
      )

  defp outstanding(id) do
    attrs = sync_attrs(id)
    max(attrs.deposit_due_cents - attrs.deposit_paid_cents, 0)
  end

  defp available_credit(guest, on),
    do:
      Repo.one(
        from l in CreditLot,
          where: l.guest_id == ^guest and l.remaining_cents > 0 and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

  defp active_applied_credit,
    do:
      Repo.one(
        from a in CreditAllocation,
          join: r in Room,
          on: r.id == a.room_id,
          where: r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

  defp credit_shortfall do
    Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.sum_by(fn lot ->
      applied =
        Repo.one(
          from a in CreditAllocation,
            join: r in Room,
            on: r.id == a.room_id,
            where: a.credit_lot_id == ^lot.id and r.status == "active",
            select: coalesce(sum(a.amount_cents), 0)
        )

      min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp update_payment!(p, attrs), do: p |> CashPayment.changeset(attrs) |> Repo.update!()
  defp update_lot!(l, attrs), do: l |> CreditLot.changeset(attrs) |> Repo.update!()

  defp policy_version_for("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version_for("flexible", booked),
    do: if(Date.compare(booked, @policy_change_on) == :lt, do: "flex-14", else: "flex-30")

  defp refundable_until(%{policy_version: "flex-14", arrival_on: date}), do: Date.add(date, -14)
  defp refundable_until(%{policy_version: "flex-30", arrival_on: date}), do: Date.add(date, -30)
  defp refundable_until(_), do: nil

  defp refundable_on?(group, occurred) do
    case refundable_until(group) do
      nil -> false
      date -> Date.compare(occurred, date) in [:lt, :eq]
    end
  end

  defp round_percentage(amount, percent), do: div(amount * percent + 50, 100)
  defp positive?(value), do: is_integer(value) and value > 0

  defp valid_rooms?(rooms, nights) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate}
        when is_binary(id) and id != "" and
               is_integer(rate) and rate >= 0 and rate <= @max_integer ->
          true

        _ ->
          false
      end)

    if valid do
      ids = Enum.map(rooms, & &1["room_id"])
      amounts = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))
      Enum.uniq(ids) == ids and Enum.sum(amounts) <= @max_integer
    else
      false
    end
  end

  defp valid_rooms?(_, _), do: false
  defp identifiers_valid?(op, keys), do: Enum.all?(keys, &(is_binary(op[&1]) and op[&1] != ""))

  defp required_identifier(op, key) do
    case Map.fetch(op, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :missing
    end
  end

  defp valid_date?(value), do: match?({:ok, _}, parse_date(value))

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, d} -> {:ok, d}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp applied(op, fields),
    do: Map.merge(fields, %{operation_id: op["operation_id"], status: "applied"})

  defp stale_rejection(op, group),
    do: %{
      operation_id: op["operation_id"],
      status: "rejected",
      code: "stale_revision",
      group_id: group.group_id,
      expected_revision: op["expected_revision"],
      actual_revision: group.revision
    }

  defp rejected(op, code, group_id) when is_map(op),
    do: rejected(op["operation_id"], code) |> Map.put(:group_id, group_id)

  defp rejected(id, code), do: %{operation_id: id, status: "rejected", code: code}

  defp reject_payment(op, code, target, group_id \\ nil) do
    result = rejected(op["operation_id"], code) |> Map.put(:payment_operation_id, target)
    if group_id, do: Map.put(result, :group_id, group_id), else: result
  end

  defp stringify_keys(map),
    do:
      Map.new(map, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
        {key, value} -> {key, stringify_value(value)}
      end)

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v), do: v
end
