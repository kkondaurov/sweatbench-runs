defmodule GroupStay.Reservations do
  @moduledoc """
  Applies ordered, durably idempotent partner operations and exposes reservation accounting views.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashAllocation,
    CashDisposition,
    CashPayment,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    PartnerOperation,
    Room
  }

  @rate_plans ~w(flexible advance_purchase)
  @max_sqlite_integer 9_223_372_036_854_775_807

  def apply_batch(operations) when is_list(operations),
    do: Enum.map(operations, &apply_operation/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, preload_rooms(group)}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> {:ok, operation.result}
    end
  end

  def get_operation_result(_), do: {:error, :operation_not_found}

  def get_payment(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        {:error, :operation_not_found}

      _ ->
        case Repo.get(CashPayment, operation_id) do
          nil -> {:error, :payment_not_reconcilable}
          payment -> {:ok, payment_json(payment)}
        end
    end
  end

  def get_payment(_), do: {:error, :operation_not_found}

  def ledger(on \\ Date.utc_today()) do
    dispositions =
      CashDisposition
      |> select([entry], {entry.kind, entry.amount_cents})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {kind, amount}, totals ->
        Map.update(totals, kind, amount, &(&1 + amount))
      end)

    %{
      cash_held_cents: sum_query(CashAllocation, :amount_cents),
      cash_refunded_cents: Map.get(dispositions, "refunded", 0),
      cash_retained_cents: Map.get(dispositions, "retained", 0),
      cash_converted_to_credit_cents: Map.get(dispositions, "converted", 0),
      cash_reduced_cents: Map.get(dispositions, "reduced", 0),
      cash_charged_back_cents: Map.get(dispositions, "charged_back", 0),
      credit_liability_cents: credit_liability(on),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      CreditLot
      |> where([lot], lot.guest_id == ^guest_id)
      |> where([lot], lot.remaining_cents > 0 and lot.expires_on >= ^on)
      |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
      |> Repo.all()

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

  def group_json(group) do
    active = Enum.filter(group.rooms, &(&1.status == "active"))
    lodging = Enum.sum(Enum.map(active, & &1.lodging_total_cents))
    due = Enum.sum(Enum.map(active, & &1.deposit_due_cents))
    cash = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(active, & &1.credit_paid_cents))

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
      rooms: Enum.map(group.rooms, &room_json/1),
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      deposit_paid_cents: cash + credit,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      outstanding_deposit_cents: max(due - cash - credit, 0)
    }
  end

  defp room_json(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status,
      lodging_total_cents: room.lodging_total_cents,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: room.cash_paid_cents,
      credit_paid_cents: room.credit_paid_cents
    }
  end

  defp apply_operation(operation) do
    operation_id = operation_id(operation)

    {:ok, result} =
      Repo.transaction(fn -> transact_operation(operation, operation_id) end, mode: :immediate)

    result
  end

  defp transact_operation(operation, operation_id)
       when is_map(operation) and is_binary(operation_id) and byte_size(operation_id) > 0 do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      %PartnerOperation{submission: submission, result: result} ->
        if submission === operation,
          do: domain_result(result),
          else: reject(operation_id, "operation_id_conflict")

      nil ->
        result = process_operation(operation, operation_id)
        stored = json_compatible(result)

        Repo.insert!(%PartnerOperation{
          operation_id: operation_id,
          operation_type: operation_type(operation),
          submission: operation,
          result: stored
        })

        domain_result(stored)
    end
  end

  defp transact_operation(_operation, operation_id), do: reject(operation_id, "invalid_operation")

  defp process_operation(%{"type" => "open_group"} = op, id), do: open_group(op, id)

  defp process_operation(%{"type" => "record_cash_payment"} = op, id),
    do: with_group(op, id, &record_cash_payment/3)

  defp process_operation(%{"type" => "reschedule_group"} = op, id),
    do: with_group(op, id, &reschedule_group/3)

  defp process_operation(%{"type" => "cancel_group"} = op, id),
    do: with_group(op, id, &cancel_group/3)

  defp process_operation(%{"type" => "cancel_rooms"} = op, id),
    do: with_group(op, id, &cancel_rooms/3)

  defp process_operation(%{"type" => "apply_hotel_credit"} = op, id),
    do: with_group(op, id, &apply_hotel_credit/3)

  defp process_operation(%{"type" => "reduce_cash_payment"} = op, id),
    do: with_payment_target(op, id, :reduce)

  defp process_operation(%{"type" => "charge_back_payment"} = op, id),
    do: with_payment_target(op, id, :charge_back)

  defp process_operation(_operation, id), do: reject(id, "invalid_operation")

  defp open_group(operation, operation_id) do
    required =
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if valid_required_fields?(operation, required) do
      if Repo.get(Group, operation["group_id"]),
        do: reject(operation_id, "group_already_exists"),
        else: validate_and_insert_group(operation, operation_id)
    else
      reject(operation_id, "invalid_operation")
    end
  end

  defp validate_and_insert_group(operation, operation_id) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         nights = Date.diff(departure_on, arrival_on),
         {:ok, lodging, due} <- calculate_totals(rooms, nights, operation["rate_plan"]) do
      group =
        Repo.insert!(%Group{
          group_id: operation["group_id"],
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: operation["rate_plan"],
          policy_version: policy_version(operation["rate_plan"], booked_on),
          status: "active",
          lodging_total_cents: lodging,
          deposit_due_cents: due,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          revision: 1
        })

      rooms
      |> Enum.with_index()
      |> Enum.each(fn {room, position} ->
        room_lodging = room["nightly_rate_cents"] * nights

        Repo.insert!(%Room{
          group_id: group.group_id,
          position: position,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"],
          status: "active",
          lodging_total_cents: room_lodging,
          deposit_due_cents: room_deposit(room_lodging, operation["rate_plan"]),
          cash_paid_cents: 0,
          credit_paid_cents: 0
        })
      end)

      applied(operation_id, %{group_id: group.group_id, deposit_due_cents: due, revision: 1})
    else
      {:error, code} when code in ["invalid_stay", "invalid_rooms", "invalid_rate_plan"] ->
        reject(operation_id, code)

      _ ->
        reject(operation_id, "invalid_operation")
    end
  end

  defp with_group(operation, operation_id, callback) do
    case operation["group_id"] do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 ->
        case Repo.get(Group, group_id) do
          nil -> reject(operation_id, "group_not_found")
          group -> check_revision(operation, operation_id, group, callback)
        end

      _ ->
        reject(operation_id, "invalid_operation")
    end
  end

  defp check_revision(operation, operation_id, group, callback) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      reject(operation_id, "stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    else
      callback.(operation, operation_id, group)
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    cond do
      not (Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "amount_cents")) ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active")

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not positive_integer?(operation["amount_cents"]) ->
        reject(operation_id, "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        reject(operation_id, "payment_exceeds_outstanding")

      true ->
        amount = operation["amount_cents"]

        Repo.insert!(%CashPayment{
          operation_id: operation_id,
          group_id: group.group_id,
          recorded_cents: amount,
          reduced_cents: 0,
          charged_back_cents: 0
        })

        allocate_cash!(group, operation_id, amount)
        group = advance_and_sync_group!(group)

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group),
          revision: group.revision
        })
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    cond do
      not (Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "new_arrival_on")) ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active")

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, arrival} <- parse_date(operation["new_arrival_on"]),
             :gt <- Date.compare(arrival, occurred_on) do
          shift = Date.diff(arrival, group.arrival_on)

          group =
            update_group!(group, %{
              arrival_on: arrival,
              departure_on: Date.add(group.departure_on, shift)
            })

          applied(operation_id, %{
            group_id: group.group_id,
            new_arrival_on: group.arrival_on,
            new_departure_on: group.departure_on,
            policy_version: group.policy_version,
            refundable_until: refundable_until(group),
            revision: group.revision
          })
        else
          _ -> reject(operation_id, "invalid_stay")
        end
    end
  end

  defp cancel_group(operation, operation_id, group) do
    method = Map.get(operation, "refund_method", "cash")

    cond do
      not Map.has_key?(operation, "occurred_on") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active")

      method not in ["cash", "hotel_credit"] ->
        reject(operation_id, "invalid_operation")

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, on} ->
            case settle_rooms(group, active_rooms(group.group_id), operation_id, on, method) do
              {:ok, settlement, updated} ->
                applied(
                  operation_id,
                  Map.merge(settlement, %{group_id: group.group_id, revision: updated.revision})
                )

              {:error, code} ->
                reject(operation_id, code)
            end

          :error ->
            reject(operation_id, "invalid_operation")
        end
    end
  end

  defp cancel_rooms(operation, operation_id, group) do
    method = Map.get(operation, "refund_method", "cash")

    cond do
      not (Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "room_ids")) ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active")

      method not in ["cash", "hotel_credit"] ->
        reject(operation_id, "invalid_operation")

      true ->
        with {:ok, on} <- parse_date(operation["occurred_on"]),
             {:ok, rooms} <- selected_active_rooms(group.group_id, operation["room_ids"]),
             {:ok, settlement, updated} <- settle_rooms(group, rooms, operation_id, on, method) do
          fields =
            settlement
            |> Map.put(:group_id, group.group_id)
            |> Map.put(:cancelled_room_ids, Enum.map(rooms, & &1.room_id))
            |> Map.put(:revision, updated.revision)

          applied(operation_id, fields)
        else
          {:error, code} -> reject(operation_id, code)
          _ -> reject(operation_id, "invalid_operation")
        end
    end
  end

  defp settle_rooms(group, rooms, operation_id, occurred_on, method) do
    refundable = refundable?(group, occurred_on)

    if not refundable and method == "hotel_credit" do
      {:error, "refund_method_not_available"}
    else
      room_ids = Enum.map(rooms, & &1.id)
      allocations = ordered_cash_allocations(room_ids)
      cash = Enum.sum(Enum.map(allocations, & &1.amount_cents))

      {refunded, retained, converted, issued, lot} =
        settle_cash!(group, allocations, cash, operation_id, occurred_on, refundable, method)

      settle_credit!(room_ids, occurred_on, refundable)

      Enum.each(rooms, fn room ->
        room
        |> Ecto.Changeset.change(%{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
        |> Repo.update!()
      end)

      updated =
        advance_and_sync_group!(group, %{
          refunded_cents: group.refunded_cents + refunded,
          retained_cents: group.retained_cents + retained,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
        })

      if lot, do: record_credit_entitlements!(lot, allocations)

      {:ok, %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued},
       updated}
    end
  end

  defp settle_cash!(group, allocations, cash, operation_id, occurred_on, refundable, method) do
    {kind, refunded, retained, converted, issued} =
      case {refundable, method} do
        {true, "cash"} -> {"refunded", cash, 0, 0, 0}
        {true, "hotel_credit"} -> {"converted", 0, 0, cash, bonus_value(cash)}
        {false, "cash"} -> {"retained", 0, cash, 0, 0}
      end

    lot =
      if issued > 0 do
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: issued,
          expires_on: Date.add(occurred_on, 365),
          unrecovered_clawback_cents: 0
        })
      end

    Enum.each(allocations, fn allocation ->
      Repo.insert!(%CashDisposition{
        group_id: group.group_id,
        payment_operation_id: allocation.payment_operation_id,
        kind: kind,
        amount_cents: allocation.amount_cents,
        credit_lot_id: lot && lot.id
      })

      Repo.delete!(allocation)
    end)

    {refunded, retained, converted, issued, lot}
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    cond do
      not (Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "amount_cents")) ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active")

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not positive_integer?(operation["amount_cents"]) ->
        reject(operation_id, "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        reject(operation_id, "payment_exceeds_outstanding")

      true ->
        {:ok, on} = parse_date(operation["occurred_on"])
        amount = operation["amount_cents"]
        lots = available_lots(group.guest_id, on)

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
          reject(operation_id, "insufficient_credit")
        else
          allocate_credit!(group, lots, operation_id, amount)
          group = advance_and_sync_group!(group)

          applied(operation_id, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(group),
            revision: group.revision
          })
        end
    end
  end

  defp with_payment_target(operation, operation_id, action) do
    case operation["payment_operation_id"] do
      target when is_binary(target) and byte_size(target) > 0 ->
        case Repo.get_by(PartnerOperation, operation_id: target) do
          nil ->
            reject(operation_id, "operation_not_found")

          _ ->
            case Repo.get(CashPayment, target) do
              nil -> reject(operation_id, payment_error(action))
              payment -> check_payment_revision(operation, operation_id, payment, action)
            end
        end

      _ ->
        reject(operation_id, "invalid_operation")
    end
  end

  defp check_payment_revision(operation, operation_id, payment, action) do
    group = Repo.get!(Group, payment.group_id)

    check_revision(operation, operation_id, group, fn operation, operation_id, group ->
      case action do
        :reduce -> reduce_cash_payment(operation, operation_id, group, payment)
        :charge_back -> charge_back_payment(operation, operation_id, group, payment)
      end
    end)
  end

  defp reduce_cash_payment(operation, operation_id, group, payment) do
    held = held_for_payment(payment.operation_id)
    amount = operation["amount_cents"]

    cond do
      not Map.has_key?(operation, "amount_cents") ->
        reject(operation_id, "invalid_operation")

      held == 0 ->
        reject(operation_id, "payment_not_reducible")

      not positive_integer?(amount) ->
        reject(operation_id, "invalid_amount")

      amount > held ->
        reject(operation_id, "reduction_exceeds_held_cash")

      true ->
        remove_held_cash!(payment.operation_id, amount)

        Repo.insert!(%CashDisposition{
          group_id: group.group_id,
          payment_operation_id: payment.operation_id,
          kind: "reduced",
          amount_cents: amount
        })

        payment
        |> Ecto.Changeset.change(%{reduced_cents: payment.reduced_cents + amount})
        |> Repo.update!()

        group = advance_and_sync_group!(group)

        applied(operation_id, %{
          payment_operation_id: payment.operation_id,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group),
          revision: group.revision
        })
    end
  end

  defp charge_back_payment(_operation, operation_id, group, payment) do
    remaining = payment.recorded_cents - payment.reduced_cents

    if remaining <= 0 or payment.charged_back_cents > 0 do
      reject(operation_id, "payment_not_chargeable")
    else
      held = held_for_payment(payment.operation_id)
      if held > 0, do: remove_held_cash!(payment.operation_id, held)

      historical =
        CashDisposition
        |> where(
          [entry],
          entry.payment_operation_id == ^payment.operation_id and
            entry.kind in ["refunded", "retained", "converted"]
        )
        |> Repo.all()

      historical
      |> Enum.filter(&(&1.kind == "converted"))
      |> Enum.map(& &1.credit_lot_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.each(&claw_back_entitlement!(&1, payment.operation_id))

      Enum.each(historical, fn entry ->
        entry
        |> Ecto.Changeset.change(%{kind: "charged_back", credit_lot_id: nil})
        |> Repo.update!()
      end)

      if held > 0,
        do:
          Repo.insert!(%CashDisposition{
            group_id: group.group_id,
            payment_operation_id: payment.operation_id,
            kind: "charged_back",
            amount_cents: held
          })

      payment |> Ecto.Changeset.change(%{charged_back_cents: remaining}) |> Repo.update!()
      group = advance_and_sync_group!(group)

      applied(operation_id, %{
        payment_operation_id: payment.operation_id,
        group_id: group.group_id,
        charged_back_cents: remaining,
        outstanding_deposit_cents: outstanding(group),
        revision: group.revision
      })
    end
  end

  defp allocate_cash!(group, operation_id, amount) do
    allocate_to_rooms!(group.group_id, amount, fn room, used ->
      Repo.insert!(%CashAllocation{
        group_id: group.group_id,
        room_id: room.id,
        payment_operation_id: operation_id,
        amount_cents: used
      })

      update_room_amount!(room, :cash_paid_cents, used)
    end)
  end

  defp allocate_credit!(group, lots, operation_id, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      used = min(lot.remaining_cents, remaining)

      Enum.each(room_chunks(group.group_id, used), fn {room, chunk} ->
        Repo.insert!(%CreditAllocation{
          group_id: group.group_id,
          room_id: room.id,
          credit_lot_id: lot.id,
          funding_operation_id: operation_id,
          amount_cents: chunk
        })

        update_room_amount!(room, :credit_paid_cents, chunk)
      end)

      lot
      |> Ecto.Changeset.change(%{remaining_cents: lot.remaining_cents - used})
      |> Repo.update!()

      if used == remaining, do: {:halt, 0}, else: {:cont, remaining - used}
    end)
  end

  defp allocate_to_rooms!(group_id, amount, callback),
    do: Enum.each(room_chunks(group_id, amount), fn {room, used} -> callback.(room, used) end)

  defp room_chunks(group_id, amount) do
    active_rooms(group_id)
    |> Enum.reduce_while({amount, []}, fn room, {remaining, chunks} ->
      capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      used = min(capacity, remaining)
      chunks = if used > 0, do: [{room, used} | chunks], else: chunks
      if used == remaining, do: {:halt, {0, chunks}}, else: {:cont, {remaining - used, chunks}}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp remove_held_cash!(payment_operation_id, amount) do
    allocations =
      CashAllocation
      |> where([a], a.payment_operation_id == ^payment_operation_id)
      |> order_by([a], desc: a.id)
      |> Repo.all()

    Enum.reduce_while(allocations, amount, fn allocation, remaining ->
      removed = min(allocation.amount_cents, remaining)
      update_room_amount!(Repo.get!(Room, allocation.room_id), :cash_paid_cents, -removed)

      if removed == allocation.amount_cents,
        do: Repo.delete!(allocation),
        else:
          allocation
          |> Ecto.Changeset.change(%{amount_cents: allocation.amount_cents - removed})
          |> Repo.update!()

      if removed == remaining, do: {:halt, 0}, else: {:cont, remaining - removed}
    end)
  end

  defp settle_credit!(room_ids, occurred_on, refundable) do
    CreditAllocation
    |> where([a], a.room_id in ^room_ids)
    |> order_by([a], asc: a.id)
    |> Repo.all()
    |> Enum.each(fn allocation ->
      if refundable, do: restore_credit!(allocation, occurred_on)
      Repo.delete!(allocation)
    end)
  end

  defp restore_credit!(allocation, occurred_on) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    absorbed = min(allocation.amount_cents, lot.unrecovered_clawback_cents)
    excess = allocation.amount_cents - absorbed
    available = if Date.compare(lot.expires_on, occurred_on) == :lt, do: 0, else: excess

    lot
    |> Ecto.Changeset.change(%{
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
      remaining_cents: lot.remaining_cents + available
    })
    |> Repo.update!()
  end

  defp record_credit_entitlements!(lot, allocations) do
    contributors =
      Enum.reduce(allocations, [], fn allocation, acc ->
        key = allocation.payment_operation_id

        case List.last(acc) do
          %{payment_operation_id: ^key} = previous ->
            List.replace_at(acc, -1, %{
              previous
              | principal_cents: previous.principal_cents + allocation.amount_cents
            })

          _ ->
            acc ++ [%{payment_operation_id: key, principal_cents: allocation.amount_cents}]
        end
      end)

    Enum.reduce(contributors, 0, fn contributor, preceding ->
      running = preceding + contributor.principal_cents

      Repo.insert!(%CreditEntitlement{
        credit_lot_id: lot.id,
        payment_operation_id: contributor.payment_operation_id,
        principal_cents: contributor.principal_cents,
        amount_cents: bonus_value(running) - bonus_value(preceding)
      })

      running
    end)
  end

  defp claw_back_entitlement!(lot_id, payment_operation_id) do
    entitlements =
      CreditEntitlement
      |> where(
        [e],
        e.credit_lot_id == ^lot_id and e.payment_operation_id == ^payment_operation_id
      )
      |> Repo.all()

    amount = Enum.sum(Enum.map(entitlements, & &1.amount_cents))

    if amount > 0 do
      lot = Repo.get!(CreditLot, lot_id)
      revoked = min(lot.remaining_cents, amount)

      lot
      |> Ecto.Changeset.change(%{
        remaining_cents: lot.remaining_cents - revoked,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + amount - revoked
      })
      |> Repo.update!()

      Enum.each(entitlements, &Repo.delete!/1)
    end
  end

  defp ordered_cash_allocations(room_ids) do
    operation_ids =
      PartnerOperation |> select([op], {op.operation_id, op.id}) |> Repo.all() |> Map.new()

    CashAllocation
    |> where([a], a.room_id in ^room_ids)
    |> Repo.all()
    |> Enum.sort_by(fn a ->
      {if(is_nil(a.payment_operation_id), do: 0, else: 1),
       Map.get(operation_ids, a.payment_operation_id, 0), a.id}
    end)
  end

  defp selected_active_rooms(group_id, room_ids) when is_list(room_ids) and room_ids != [] do
    valid =
      Enum.all?(room_ids, &(is_binary(&1) and byte_size(&1) > 0)) and
        length(Enum.uniq(room_ids)) == length(room_ids)

    requested = MapSet.new(room_ids)
    selected = active_rooms(group_id) |> Enum.filter(&MapSet.member?(requested, &1.room_id))

    if valid and length(selected) == length(room_ids),
      do: {:ok, selected},
      else: {:error, "invalid_rooms"}
  end

  defp selected_active_rooms(_group_id, _room_ids), do: {:error, "invalid_rooms"}

  defp active_rooms(group_id),
    do:
      Room
      |> where([r], r.group_id == ^group_id and r.status == "active")
      |> order_by([r], asc: r.position)
      |> Repo.all()

  defp available_lots(guest_id, on),
    do:
      CreditLot
      |> where([l], l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on)
      |> order_by([l], asc: l.expires_on, asc: l.source_operation_id, asc: l.id)
      |> Repo.all()

  defp advance_and_sync_group!(group, extra \\ %{}) do
    rooms = active_rooms(group.group_id)
    lodging = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
    due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))
    cash = Enum.sum(Enum.map(rooms, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(rooms, & &1.credit_paid_cents))

    changes = %{
      status: if(rooms == [], do: "cancelled", else: "active"),
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    }

    update_group!(group, Map.merge(changes, extra))
  end

  defp update_group!(group, changes),
    do:
      group
      |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
      |> Repo.update!()

  defp update_room_amount!(room, field, delta),
    do:
      room |> Ecto.Changeset.change(%{field => Map.fetch!(room, field) + delta}) |> Repo.update!()

  defp payment_json(payment) do
    dispositions = payment_dispositions(payment.operation_id)

    %{
      payment_operation_id: payment.operation_id,
      original_group_id: payment.group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: held_for_payment(payment.operation_id),
      refunded_cents: Map.get(dispositions, "refunded", 0),
      retained_cents: Map.get(dispositions, "retained", 0),
      converted_to_credit_cents: Map.get(dispositions, "converted", 0),
      reduced_cents: Map.get(dispositions, "reduced", 0),
      charged_back_cents: Map.get(dispositions, "charged_back", 0)
    }
  end

  defp payment_dispositions(id),
    do:
      CashDisposition
      |> where([e], e.payment_operation_id == ^id)
      |> select([e], {e.kind, e.amount_cents})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {kind, amount}, totals ->
        Map.update(totals, kind, amount, &(&1 + amount))
      end)

  defp held_for_payment(id),
    do:
      CashAllocation
      |> where([a], a.payment_operation_id == ^id)
      |> select([a], a.amount_cents)
      |> Repo.all()
      |> Enum.sum()

  defp sum_query(schema, field),
    do: schema |> select([row], field(row, ^field)) |> Repo.all() |> Enum.sum()

  defp credit_liability(on) do
    available =
      CreditLot
      |> where([l], l.remaining_cents > 0 and l.expires_on >= ^on)
      |> select([l], l.remaining_cents)
      |> Repo.all()
      |> Enum.sum()

    available + sum_query(CreditAllocation, :amount_cents)
  end

  defp credit_shortfall do
    applied =
      CreditAllocation
      |> select([a], {a.credit_lot_id, a.amount_cents})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {lot_id, amount}, totals ->
        Map.update(totals, lot_id, amount, &(&1 + amount))
      end)

    CreditLot
    |> where([l], l.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.sum_by(&min(&1.unrecovered_clawback_cents, Map.get(applied, &1.id, 0)))
  end

  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on),
    do: if(Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30")

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival}),
    do: Date.add(arrival, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival}),
    do: Date.add(arrival, -30)

  defp refundable_until(_), do: nil

  defp refundable?(group, on) do
    case refundable_until(group) do
      nil -> false
      cutoff -> Date.compare(on, cutoff) != :gt
    end
  end

  defp outstanding(group),
    do:
      active_rooms(group.group_id)
      |> Enum.sum_by(&max(&1.deposit_due_cents - &1.cash_paid_cents - &1.credit_paid_cents, 0))

  defp preload_rooms(group),
    do: Repo.preload(group, [rooms: from(r in Room, order_by: r.position)], force: true)

  defp valid_required_fields?(operation, fields),
    do:
      is_map(operation) and
        Enum.all?(fields, &(Map.has_key?(operation, &1) and not is_nil(operation[&1]))) and
        Enum.all?(
          ~w(operation_id group_id guest_id property_id),
          &(is_binary(operation[&1]) and byte_size(operation[&1]) > 0)
        )

  defp validate_stay(arrival, departure),
    do: if(Date.compare(departure, arrival) == :gt, do: :ok, else: {:error, "invalid_stay"})

  defp validate_rate_plan(plan) when plan in @rate_plans, do: :ok
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate}
        when is_binary(id) and byte_size(id) > 0 and is_integer(rate) and rate > 0 and
               rate <= @max_sqlite_integer ->
          true

        _ ->
          false
      end)

    if valid and Enum.uniq_by(rooms, &Map.get(&1, "room_id")) == rooms,
      do: {:ok, rooms},
      else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}

  defp calculate_totals(rooms, nights, plan) do
    lodging = Enum.sum(Enum.map(rooms, &(&1["nightly_rate_cents"] * nights)))
    due = Enum.sum(Enum.map(rooms, &room_deposit(&1["nightly_rate_cents"] * nights, plan)))

    if lodging <= @max_sqlite_integer and due <= @max_sqlite_integer,
      do: {:ok, lodging, due},
      else: {:error, "invalid_rooms"}
  end

  defp room_deposit(lodging, "advance_purchase"), do: lodging
  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp bonus_value(cash), do: cash + div(cash * 10 + 50, 100)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: :error
  defp valid_date?(value), do: match?({:ok, _}, parse_date(value))
  defp operation_id(%{"operation_id" => id}), do: id
  defp operation_id(_), do: nil
  defp payment_error(:reduce), do: "payment_not_reducible"
  defp payment_error(:charge_back), do: "payment_not_chargeable"
  defp applied(id, fields), do: Map.merge(%{operation_id: id, status: "applied"}, fields)

  defp reject(id, code, fields \\ %{}),
    do: Map.merge(%{operation_id: id, status: "rejected", code: code}, fields)

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_), do: nil
  defp json_compatible(result), do: result |> Jason.encode!() |> Jason.decode!()

  @result_keys ~w(operation_id status code group_id deposit_due_cents revision amount_cents outstanding_deposit_cents new_arrival_on new_departure_on policy_version refundable_until refunded_cents retained_cents credit_issued_cents expected_revision actual_revision cancelled_room_ids payment_operation_id charged_back_cents)a
  @date_result_keys ~w(new_arrival_on new_departure_on refundable_until)a
  defp domain_result(result),
    do:
      Map.new(result, fn {key, value} ->
        atom = Enum.find(@result_keys, key, &(Atom.to_string(&1) == key))
        {atom, domain_result_value(atom, value)}
      end)

  defp domain_result_value(key, value) when key in @date_result_keys and is_binary(value),
    do: Date.from_iso8601!(value)

  defp domain_result_value(_, value), do: value
end
