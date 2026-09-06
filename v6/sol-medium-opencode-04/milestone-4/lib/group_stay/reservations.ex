defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashAllocation,
    CashPayment,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    Operation,
    Room
  }

  @rate_plans ["flexible", "advance_purchase"]

  def process(%{"operation_id" => operation_id} = operation)
      when is_binary(operation_id) and operation_id != "" do
    {:ok, result} =
      Repo.transact(fn -> {:ok, process_durable(operation_id, operation)} end, mode: :immediate)

    result
  end

  def process(operation) when is_map(operation),
    do: rejected_result(operation["operation_id"], %{"code" => "invalid_operation"})

  def process(_operation),
    do: %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}

  def get_operation(operation_id) when is_binary(operation_id),
    do: Repo.get_by(Operation, operation_id: operation_id)

  def get_operation(_operation_id), do: nil

  def get_group(group_id) when is_binary(group_id) do
    Repo.transact(fn ->
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          {:ok, nil}

        group ->
          group = ensure_accounting!(group)
          {:ok, Repo.preload(group, :rooms, force: true)}
      end
    end)
    |> elem(1)
  end

  def get_group(_group_id), do: nil

  def group_json(%Group{} = group) do
    rooms = Enum.sort_by(group.rooms, & &1.position)
    room_data = Enum.map(rooms, &room_json/1)
    active = Enum.filter(room_data, &(&1["status"] == "active"))
    cash = Enum.sum_by(active, & &1["cash_paid_cents"])
    credit = Enum.sum_by(active, & &1["credit_paid_cents"])
    due = Enum.sum_by(active, & &1["deposit_due_cents"])

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group.policy_version,
      "refundable_until" => format_date(refundable_until(group)),
      "status" => group.status,
      "rooms" => room_data,
      "lodging_total_cents" => Enum.sum_by(active, & &1["lodging_total_cents"]),
      "deposit_due_cents" => due,
      "deposit_paid_cents" => cash + credit,
      "cash_paid_cents" => cash,
      "credit_paid_cents" => credit,
      "outstanding_deposit_cents" => max(due - cash - credit, 0)
    }
  end

  def get_payment(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        :not_found

      operation ->
        ensure_operation_group_accounting!(operation)

        case Repo.get_by(CashPayment, operation_id: operation.operation_id) do
          nil -> :not_reconcilable
          payment -> {:ok, payment_json(payment)}
        end
    end
  end

  def get_payment(_operation_id), do: :not_found

  def report_date(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def report_date(%{"on" => _}), do: :error
  def report_date(_params), do: {:ok, Date.utc_today()}

  def ledger(on \\ Date.utc_today()) do
    ensure_all_accounting!()

    cash =
      Repo.one(
        from p in CashPayment,
          select:
            {coalesce(sum(p.refunded_cents), 0), coalesce(sum(p.retained_cents), 0),
             coalesce(sum(p.converted_to_credit_cents), 0), coalesce(sum(p.reduced_cents), 0),
             coalesce(sum(p.charged_back_cents), 0)}
      )

    held = Repo.one(from a in CashAllocation, select: coalesce(sum(a.amount_cents), 0))
    {refunded, retained, converted, reduced, charged_back} = cash

    available_credit =
      Repo.one(
        from l in CreditLot,
          where: l.issued_on <= ^on and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    allocated_credit =
      Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))

    shortfall =
      Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
      |> Enum.sum_by(fn lot ->
        applied =
          Repo.one(
            from a in CreditAllocation,
              where: a.credit_lot_id == ^lot.id,
              select: coalesce(sum(a.amount_cents), 0)
          )

        min(lot.unrecovered_clawback_cents, applied)
      end)

    %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained,
      "cash_converted_to_credit_cents" => converted,
      "cash_reduced_cents" => reduced,
      "cash_charged_back_cents" => charged_back,
      "credit_liability_cents" => available_credit + allocated_credit,
      "credit_shortfall_cents" => shortfall
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = available_lots(guest_id, on)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum_by(lots, & &1.remaining_cents),
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  # Called by the request-04 migration after the new allocation tables exist.
  def backfill_accounting! do
    ensure_all_accounting!()
  end

  defp process_durable(operation_id, submission) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      %Operation{submission: stored_submission, result: result} ->
        if stored_submission === submission,
          do: result,
          else: rejected_result(operation_id, %{"code" => "operation_id_conflict"})

      nil ->
        result = execute(submission, operation_id)
        operation_type = if is_binary(submission["type"]), do: submission["type"]

        Repo.insert!(
          Operation.changeset(%Operation{}, %{
            operation_id: operation_id,
            operation_type: operation_type,
            submission: submission,
            result: result
          })
        )

        result
    end
  end

  defp execute(operation, operation_id) do
    case apply_operation(operation) do
      {:ok, fields} ->
        fields |> Map.put("status", "applied") |> Map.put("operation_id", operation_id)

      {:error, fields} ->
        rejected_result(operation_id, fields)
    end
  end

  defp rejected_result(operation_id, fields),
    do: fields |> Map.put("status", "rejected") |> Map.put("operation_id", operation_id)

  defp apply_operation(
         %{"operation_id" => operation_id, "type" => type, "occurred_on" => occurred_on} = op
       )
       when is_binary(operation_id) and operation_id != "" and is_binary(type) and
              is_binary(occurred_on) do
    with {:ok, date} <- Date.from_iso8601(occurred_on) do
      case type do
        "open_group" ->
          open_group(op, date)

        "record_cash_payment" ->
          with_group(op, &record_cash_payment(&1, op))

        "apply_hotel_credit" ->
          with_group(op, &apply_hotel_credit(&1, op, date))

        "reschedule_group" ->
          with_group(op, &reschedule_group(&1, op, date))

        "cancel_group" ->
          with_group(op, &cancel_group(&1, op, date))

        "cancel_rooms" ->
          with_group(op, &cancel_rooms(&1, op, date))

        "reduce_cash_payment" ->
          with_payment_target(op, "payment_not_reducible", &reduce_cash(&1, &2, op))

        "charge_back_payment" ->
          with_payment_target(op, "payment_not_chargeable", &charge_back(&1, &2, op))

        _ ->
          reject("invalid_operation")
      end
    else
      _ -> reject("invalid_operation")
    end
  end

  defp apply_operation(_operation), do: reject("invalid_operation")

  defp open_group(op, booked_on) do
    required = ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if Enum.all?(required, &Map.has_key?(op, &1)),
      do: do_open_group(op, booked_on),
      else: reject("invalid_operation")
  end

  defp do_open_group(op, booked_on) do
    with :ok <- validate_identifier(op["group_id"]),
         :ok <- validate_identifier(op["guest_id"]),
         :ok <- validate_identifier(op["property_id"]),
         :ok <- validate_group_is_new(op["group_id"]),
         {:ok, arrival_on} <- parse_date(op["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(op["departure_on"], "invalid_stay"),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on),
         :ok <- validate_rate_plan(op["rate_plan"]),
         {:ok, rooms} <- validate_rooms(op["rooms"]) do
      room_amounts = Enum.map(rooms, &room_amounts(&1, nights, op["rate_plan"]))
      lodging = Enum.sum_by(room_amounts, & &1.lodging_total_cents)
      due = Enum.sum_by(room_amounts, & &1.deposit_due_cents)

      attrs = %{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: op["rate_plan"],
        policy_version: policy_version(op["rate_plan"], booked_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging,
        deposit_due_cents: due,
        accounting_backfilled: true
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          room_amounts
          |> Enum.with_index()
          |> Enum.each(fn {room, position} ->
            room
            |> Map.from_struct()
            |> Map.merge(%{position: position, group_reservation_id: group.id, status: "active"})
            |> then(&Repo.insert!(Room.changeset(%Room{}, &1)))
          end)

          {:ok, %{"group_id" => group.group_id, "deposit_due_cents" => due, "revision" => 1}}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id),
            do: reject("group_already_exists"),
            else: reject("invalid_operation")
      end
    else
      {:error, code} -> reject(code)
      _ -> reject("invalid_stay")
    end
  end

  defp with_group(%{"group_id" => group_id} = op, callback)
       when is_binary(group_id) and group_id != "" do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        reject("group_not_found", %{"group_id" => group_id})

      group ->
        group = ensure_accounting!(group)

        case check_revision(group, op),
          do: (
            :ok -> callback.(group)
            error -> error
          )
    end
  end

  defp with_group(_op, _callback), do: reject("invalid_operation")

  defp with_payment_target(%{"payment_operation_id" => operation_id} = op, invalid_code, callback)
       when is_binary(operation_id) and operation_id != "" do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        reject("operation_not_found")

      operation ->
        ensure_operation_group_accounting!(operation)
        payment = Repo.get_by(CashPayment, operation_id: operation.operation_id)

        if payment do
          group = Repo.get!(Group, payment.group_reservation_id) |> ensure_accounting!()
          payment = Repo.get_by!(CashPayment, operation_id: operation.operation_id)

          case check_revision(group, op),
            do: (
              :ok -> callback.(payment, group)
              error -> error
            )
        else
          reject(invalid_code)
        end
    end
  end

  defp with_payment_target(_op, _invalid_code, _callback), do: reject("invalid_operation")

  defp check_revision(group, %{"expected_revision" => expected}) when is_integer(expected) do
    if expected == group.revision do
      :ok
    else
      reject("stale_revision", %{
        "group_id" => group.group_id,
        "expected_revision" => expected,
        "actual_revision" => group.revision
      })
    end
  end

  defp check_revision(_group, %{"expected_revision" => _}), do: reject("invalid_operation")
  defp check_revision(_group, _op), do: :ok

  defp record_cash_payment(group, op) do
    cond do
      not Map.has_key?(op, "amount_cents") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      not positive_integer?(op["amount_cents"]) ->
        reject("invalid_amount")

      op["amount_cents"] > outstanding(group) ->
        reject("payment_exceeds_outstanding")

      true ->
        amount = op["amount_cents"]

        payment =
          Repo.insert!(
            CashPayment.changeset(%CashPayment{}, %{
              operation_id: op["operation_id"],
              group_reservation_id: group.id,
              recorded_cents: amount
            })
          )

        allocate_cash!(payment, active_rooms(group.id), amount)
        updated = sync_group!(group)

        {:ok,
         %{
           "group_id" => group.group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => outstanding(updated),
           "revision" => updated.revision
         }}
    end
  end

  defp apply_hotel_credit(group, op, occurred_on) do
    cond do
      not Map.has_key?(op, "amount_cents") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      not positive_integer?(op["amount_cents"]) ->
        reject("invalid_amount")

      op["amount_cents"] > outstanding(group) ->
        reject("payment_exceeds_outstanding")

      true ->
        lots = available_lots(group.guest_id, occurred_on)
        amount = op["amount_cents"]

        if Enum.sum_by(lots, & &1.remaining_cents) < amount do
          reject("insufficient_credit")
        else
          consume_credit!(lots, group, op["operation_id"], amount)
          updated = sync_group!(group)

          {:ok,
           %{
             "group_id" => group.group_id,
             "amount_cents" => amount,
             "outstanding_deposit_cents" => outstanding(updated),
             "revision" => updated.revision
           }}
        end
    end
  end

  defp reschedule_group(group, op, occurred_on) do
    cond do
      not Map.has_key?(op, "new_arrival_on") ->
        reject("invalid_operation")

      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      true ->
        with {:ok, new_arrival} <- parse_date(op["new_arrival_on"], "invalid_stay"),
             true <- Date.after?(new_arrival, occurred_on) do
          shift = Date.diff(new_arrival, group.arrival_on)

          updated =
            update_group!(group, %{
              arrival_on: new_arrival,
              departure_on: Date.add(group.departure_on, shift)
            })

          {:ok,
           %{
             "group_id" => group.group_id,
             "new_arrival_on" => Date.to_iso8601(updated.arrival_on),
             "new_departure_on" => Date.to_iso8601(updated.departure_on),
             "policy_version" => updated.policy_version,
             "refundable_until" => format_date(refundable_until(updated)),
             "revision" => updated.revision
           }}
        else
          _ -> reject("invalid_stay")
        end
    end
  end

  defp cancel_group(group, op, occurred_on) do
    if group.status != "active" do
      reject("group_not_active", %{"group_id" => group.group_id})
    else
      settle_rooms(group, active_rooms(group.id), op, occurred_on, false)
    end
  end

  defp cancel_rooms(group, op, occurred_on) do
    cond do
      group.status != "active" ->
        reject("group_not_active", %{"group_id" => group.group_id})

      not Map.has_key?(op, "room_ids") ->
        reject("invalid_operation")

      not is_list(op["room_ids"]) or op["room_ids"] == [] ->
        reject("invalid_rooms")

      true ->
        requested = op["room_ids"]
        rooms = active_rooms(group.id) |> Enum.filter(&(&1.room_id in requested))

        if Enum.uniq(requested) != requested or length(rooms) != length(requested),
          do: reject("invalid_rooms"),
          else: settle_rooms(group, rooms, op, occurred_on, true)
    end
  end

  defp settle_rooms(group, rooms, op, occurred_on, include_room_ids) do
    refund_method = Map.get(op, "refund_method", "cash")

    cond do
      refund_method not in ["cash", "hotel_credit"] ->
        reject("invalid_operation")

      refund_method == "hotel_credit" and not refundable?(group, occurred_on) ->
        reject("refund_method_not_available")

      true ->
        do_settle_rooms(group, rooms, op, refund_method, occurred_on, include_room_ids)
    end
  end

  defp do_settle_rooms(group, rooms, op, refund_method, occurred_on, include_room_ids) do
    refundable = refundable?(group, occurred_on)
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from a in CashAllocation,
          join: p in assoc(a, :cash_payment),
          where: a.group_room_id in ^room_ids,
          preload: [cash_payment: p],
          order_by: [asc: p.id, asc: a.id]
      )

    contributions =
      allocations
      |> Enum.group_by(& &1.cash_payment)
      |> Enum.map(fn {payment, rows} -> {payment, Enum.sum_by(rows, & &1.amount_cents)} end)
      |> Enum.sort_by(fn {payment, _} -> payment.id end)

    cash_amount = Enum.sum_by(contributions, &elem(&1, 1))
    {refunded, retained, converted} = settlement_amounts(cash_amount, refundable, refund_method)

    Enum.each(contributions, fn {payment, amount} ->
      attrs =
        cond do
          refunded > 0 ->
            %{refunded_cents: payment.refunded_cents + amount}

          retained > 0 ->
            %{retained_cents: payment.retained_cents + amount}

          converted > 0 ->
            %{converted_to_credit_cents: payment.converted_to_credit_cents + amount}

          true ->
            %{}
        end

      payment |> CashPayment.changeset(attrs) |> Repo.update!()
    end)

    Enum.each(allocations, &Repo.delete!/1)

    credit_issued =
      if converted > 0 do
        issue_credit!(group, op["operation_id"], occurred_on, contributions)
      else
        0
      end

    settle_credit_allocations!(room_ids, refundable, occurred_on)

    Enum.each(rooms, fn room ->
      room |> Room.changeset(%{status: "cancelled"}) |> Repo.update!()
    end)

    status =
      if Repo.exists?(
           from r in Room, where: r.group_reservation_id == ^group.id and r.status == "active"
         ), do: "active", else: "cancelled"

    updated =
      sync_group!(group, %{
        status: status,
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
      })

    result = %{
      "group_id" => group.group_id,
      "refunded_cents" => refunded,
      "retained_cents" => retained,
      "credit_issued_cents" => credit_issued,
      "revision" => updated.revision
    }

    if include_room_ids,
      do: {:ok, Map.put(result, "cancelled_room_ids", Enum.map(rooms, & &1.room_id))},
      else: {:ok, result}
  end

  defp reduce_cash(payment, group, op) do
    held = held_cash(payment.id)

    cond do
      not Map.has_key?(op, "amount_cents") ->
        reject("invalid_operation")

      held == 0 ->
        reject("payment_not_reducible")

      not positive_integer?(op["amount_cents"]) ->
        reject("invalid_amount")

      op["amount_cents"] > held ->
        reject("reduction_exceeds_held_cash")

      true ->
        amount = op["amount_cents"]
        remove_cash_allocations!(payment.id, amount)

        payment
        |> CashPayment.changeset(%{reduced_cents: payment.reduced_cents + amount})
        |> Repo.update!()

        updated = sync_group!(group, %{cash_reduced_cents: group.cash_reduced_cents + amount})

        {:ok,
         %{
           "payment_operation_id" => payment.operation_id,
           "group_id" => group.group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => outstanding(updated),
           "revision" => updated.revision
         }}
    end
  end

  defp charge_back(payment, group, _op) do
    remaining = payment.recorded_cents - payment.reduced_cents - payment.charged_back_cents

    if remaining <= 0 do
      reject("payment_not_chargeable")
    else
      held = held_cash(payment.id)
      remove_cash_allocations!(payment.id, held)
      revoke_entitlements!(payment)

      payment
      |> CashPayment.changeset(%{
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: payment.charged_back_cents + remaining
      })
      |> Repo.update!()

      updated =
        sync_group!(group, %{
          refunded_cents: group.refunded_cents - payment.refunded_cents,
          retained_cents: group.retained_cents - payment.retained_cents,
          cash_converted_to_credit_cents:
            group.cash_converted_to_credit_cents - payment.converted_to_credit_cents,
          cash_charged_back_cents: group.cash_charged_back_cents + remaining
        })

      {:ok,
       %{
         "payment_operation_id" => payment.operation_id,
         "group_id" => group.group_id,
         "charged_back_cents" => remaining,
         "outstanding_deposit_cents" => outstanding(updated),
         "revision" => updated.revision
       }}
    end
  end

  defp room_json(room) do
    cash =
      Repo.one(
        from a in CashAllocation,
          where: a.group_room_id == ^room.id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one(
        from a in CreditAllocation,
          where: a.group_room_id == ^room.id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status,
      "lodging_total_cents" => room.lodging_total_cents,
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => cash,
      "credit_paid_cents" => credit
    }
  end

  defp allocate_cash!(payment, rooms, amount) do
    allocate_to_rooms(rooms, amount, fn room, used ->
      Repo.insert!(
        CashAllocation.changeset(%CashAllocation{}, %{
          cash_payment_id: payment.id,
          group_room_id: room.id,
          amount_cents: used
        })
      )
    end)
  end

  defp consume_credit!(lots, group, operation_id, amount) do
    rooms = active_rooms(group.id)

    {_, lot_chunks} =
      Enum.reduce_while(lots, {amount, []}, fn lot, {remaining, chunks} ->
        used = min(lot.remaining_cents, remaining)

        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - used})
        |> Repo.update!()

        next = {remaining - used, chunks ++ [{lot, used}]}
        if used == remaining, do: {:halt, next}, else: {:cont, next}
      end)

    allocate_credit_chunks!(rooms, lot_chunks, group.id, operation_id)
  end

  defp allocate_credit_chunks!(rooms, chunks, group_id, operation_id) do
    room_needs = Enum.map(rooms, &{&1, room_outstanding(&1)})

    Enum.reduce(chunks, room_needs, fn {lot, chunk_amount}, needs ->
      {next_needs, 0} =
        Enum.map_reduce(needs, chunk_amount, fn {room, need}, remaining ->
          used = min(need, remaining)

          if used > 0 do
            Repo.insert!(
              CreditAllocation.changeset(%CreditAllocation{}, %{
                credit_lot_id: lot.id,
                group_reservation_id: group_id,
                group_room_id: room.id,
                funding_operation_id: operation_id,
                amount_cents: used
              })
            )
          end

          {{room, need - used}, remaining - used}
        end)

      next_needs
    end)
  end

  defp allocate_to_rooms(rooms, amount, inserter) do
    Enum.reduce_while(rooms, amount, fn room, remaining ->
      used = min(room_outstanding(room), remaining)
      if used > 0, do: inserter.(room, used)
      if used == remaining, do: {:halt, 0}, else: {:cont, remaining - used}
    end)
  end

  defp remove_cash_allocations!(_payment_id, 0), do: :ok

  defp remove_cash_allocations!(payment_id, amount) do
    allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.cash_payment_id == ^payment_id,
          order_by: [desc: a.id]
      )

    Enum.reduce_while(allocations, amount, fn allocation, remaining ->
      removed = min(allocation.amount_cents, remaining)

      if removed == allocation.amount_cents do
        Repo.delete!(allocation)
      else
        allocation
        |> CashAllocation.changeset(%{amount_cents: allocation.amount_cents - removed})
        |> Repo.update!()
      end

      if removed == remaining, do: {:halt, 0}, else: {:cont, remaining - removed}
    end)
  end

  defp issue_credit!(group, operation_id, occurred_on, contributions) do
    principal = Enum.sum_by(contributions, &elem(&1, 1))
    total = bonus_value(principal)

    lot =
      Repo.insert!(
        CreditLot.changeset(%CreditLot{}, %{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: total,
          issued_on: occurred_on,
          expires_on: Date.add(occurred_on, 365)
        })
      )

    {_running, _entitled} =
      Enum.reduce(contributions, {0, 0}, fn {payment, amount}, {running, entitled} ->
        next_running = running + amount
        next_entitled = bonus_value(next_running)
        entitlement = next_entitled - entitled

        unless legacy_payment?(payment) do
          Repo.insert!(
            CreditEntitlement.changeset(%CreditEntitlement{}, %{
              credit_lot_id: lot.id,
              cash_payment_id: payment.id,
              amount_cents: entitlement
            })
          )
        end

        {next_running, next_entitled}
      end)

    total
  end

  defp settle_credit_allocations!(room_ids, refundable, occurred_on) do
    Repo.all(
      from a in CreditAllocation, where: a.group_room_id in ^room_ids, preload: [:credit_lot]
    )
    |> Enum.each(fn allocation ->
      if refundable do
        lot = Repo.get!(CreditLot, allocation.credit_lot_id)
        restore_credit!(lot, allocation.amount_cents, occurred_on)
      end

      Repo.delete!(allocation)
    end)
  end

  defp restore_credit!(lot, amount, occurred_on) do
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    available = amount - absorbed
    unexpired = not Date.before?(lot.expires_on, occurred_on)

    attrs = %{
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
      remaining_cents: lot.remaining_cents + if(unexpired, do: available, else: 0)
    }

    lot |> CreditLot.changeset(attrs) |> Repo.update!()
  end

  defp revoke_entitlements!(payment) do
    Repo.all(
      from e in CreditEntitlement, where: e.cash_payment_id == ^payment.id, preload: [:credit_lot]
    )
    |> Enum.each(fn entitlement ->
      amount = entitlement.amount_cents - entitlement.revoked_cents
      removed = min(entitlement.credit_lot.remaining_cents, amount)

      entitlement.credit_lot
      |> CreditLot.changeset(%{
        remaining_cents: entitlement.credit_lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          entitlement.credit_lot.unrecovered_clawback_cents + amount - removed
      })
      |> Repo.update!()

      entitlement
      |> CreditEntitlement.changeset(%{revoked_cents: entitlement.revoked_cents + amount})
      |> Repo.update!()
    end)
  end

  defp ensure_all_accounting! do
    Repo.all(from g in Group, where: g.accounting_backfilled == false)
    |> Enum.each(&ensure_accounting!/1)
  end

  defp ensure_accounting!(%Group{accounting_backfilled: true} = group), do: group

  defp ensure_accounting!(group) do
    rooms =
      Repo.all(from r in Room, where: r.group_reservation_id == ^group.id, order_by: r.position)

    durable =
      Repo.all(
        from o in Operation,
          where: o.operation_type == "record_cash_payment",
          order_by: o.id
      )
      |> Enum.filter(fn operation ->
        operation.result["status"] == "applied" and operation.result["group_id"] == group.group_id
      end)

    durable_total = Enum.sum_by(durable, & &1.result["amount_cents"])
    legacy_amount = max(group.cash_paid_cents - durable_total, 0)

    payments =
      if legacy_amount > 0 do
        [create_legacy_payment!(group, legacy_amount)]
      else
        []
      end ++
        Enum.map(durable, fn operation ->
          Repo.get_by(CashPayment, operation_id: operation.operation_id) ||
            Repo.insert!(
              CashPayment.changeset(%CashPayment{}, %{
                operation_id: operation.operation_id,
                group_reservation_id: group.id,
                recorded_cents: operation.result["amount_cents"]
              })
            )
        end)

    if group.status == "active" do
      backfill_active_funding!(group, rooms, payments, durable, legacy_amount)
    else
      classify_historical_payments!(payments, group)
      backfill_credit_allocations!(group, rooms)
    end

    group
    |> Group.changeset(%{accounting_backfilled: true})
    |> Repo.update!()
  end

  defp create_legacy_payment!(group, amount) do
    Repo.insert!(
      CashPayment.changeset(%CashPayment{}, %{
        operation_id: "__legacy__:#{group.id}",
        group_reservation_id: group.id,
        recorded_cents: amount
      })
    )
  end

  defp backfill_active_funding!(group, rooms, payments, durable_cash, legacy_cash) do
    credit_rows =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_reservation_id == ^group.id,
          order_by: a.id,
          preload: [:credit_lot]
      )

    Enum.each(credit_rows, &Repo.delete!/1)
    credit_chunks = Enum.map(credit_rows, &{&1.credit_lot, &1.amount_cents})

    durable_credit =
      Repo.all(
        from o in Operation, where: o.operation_type == "apply_hotel_credit", order_by: o.id
      )
      |> Enum.filter(fn operation ->
        operation.result["status"] == "applied" and operation.result["group_id"] == group.group_id
      end)

    durable_credit_total = Enum.sum_by(durable_credit, & &1.result["amount_cents"])
    legacy_credit = max(group.credit_paid_cents - durable_credit_total, 0)
    payment_by_operation = Map.new(payments, &{&1.operation_id, &1})

    if legacy_cash > 0 do
      allocate_cash!(
        Map.fetch!(payment_by_operation, "__legacy__:#{group.id}"),
        rooms,
        legacy_cash
      )
    end

    {chunks, _used} =
      allocate_backfill_credit!(rooms, credit_chunks, legacy_credit, group.id, nil)

    (durable_cash ++ durable_credit)
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce(chunks, fn operation, remaining_chunks ->
      if operation.operation_type == "record_cash_payment" do
        payment = Map.fetch!(payment_by_operation, operation.operation_id)
        allocate_cash!(payment, rooms, payment.recorded_cents)
        remaining_chunks
      else
        {rest, _used} =
          allocate_backfill_credit!(
            rooms,
            remaining_chunks,
            operation.result["amount_cents"],
            group.id,
            operation.operation_id
          )

        rest
      end
    end)
  end

  defp allocate_backfill_credit!(rooms, chunks, amount, group_id, operation_id) do
    {used, remaining} = take_credit_chunks(chunks, amount, [])
    allocate_credit_chunks!(rooms, used, group_id, operation_id)
    {remaining, used}
  end

  defp take_credit_chunks(chunks, 0, used), do: {Enum.reverse(used), chunks}

  defp take_credit_chunks([{lot, amount} | rest], needed, used) do
    consumed = min(amount, needed)
    remaining = if consumed == amount, do: rest, else: [{lot, amount - consumed} | rest]
    take_credit_chunks(remaining, needed - consumed, [{lot, consumed} | used])
  end

  defp take_credit_chunks([], _needed, used), do: {Enum.reverse(used), []}

  defp classify_historical_payments!(payments, group) do
    disposition =
      cond do
        group.refunded_cents > 0 -> :refunded_cents
        group.retained_cents > 0 -> :retained_cents
        group.cash_converted_to_credit_cents > 0 -> :converted_to_credit_cents
        true -> nil
      end

    if disposition do
      Enum.reduce(payments, Map.fetch!(group_to_map(group), disposition), fn payment, remaining ->
        amount = min(payment.recorded_cents, remaining)
        payment |> CashPayment.changeset(%{disposition => amount}) |> Repo.update!()
        remaining - amount
      end)
    end

    if disposition == :converted_to_credit_cents do
      lot =
        Repo.get_by(CreditLot, source_operation_id: historical_cancel_operation(group.group_id))

      if lot, do: create_historical_entitlements!(lot, payments)
    end
  end

  defp group_to_map(group), do: Map.from_struct(group)

  defp historical_cancel_operation(group_id) do
    Repo.all(
      from o in Operation,
        where: o.operation_type in ["cancel_group", "cancel_rooms"],
        order_by: o.id
    )
    |> Enum.find_value(fn operation ->
      if operation.result["status"] == "applied" and operation.result["group_id"] == group_id and
           operation.result["credit_issued_cents"] > 0,
         do: operation.operation_id
    end)
  end

  defp create_historical_entitlements!(lot, payments) do
    Enum.reduce(payments, {0, 0}, fn payment, {running, entitled} ->
      amount = payment.converted_to_credit_cents
      next_running = running + amount
      next_entitled = bonus_value(next_running)
      value = next_entitled - entitled

      if value > 0 and not legacy_payment?(payment) do
        Repo.insert!(
          CreditEntitlement.changeset(%CreditEntitlement{}, %{
            credit_lot_id: lot.id,
            cash_payment_id: payment.id,
            amount_cents: value
          })
        )
      end

      {next_running, next_entitled}
    end)
  end

  defp backfill_credit_allocations!(group, rooms) do
    old =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_reservation_id == ^group.id,
          order_by: a.id,
          preload: [:credit_lot]
      )

    if old != [] and Enum.any?(old, &is_nil(&1.group_room_id)) do
      Enum.each(old, &Repo.delete!/1)
      chunks = Enum.map(old, &{&1.credit_lot, &1.amount_cents})
      allocate_credit_chunks!(rooms, chunks, group.id, nil)
    end
  end

  defp ensure_operation_group_accounting!(operation) do
    if operation.operation_type == "record_cash_payment" and
         operation.result["status"] == "applied" do
      case Repo.get_by(Group, group_id: operation.result["group_id"]) do
        nil -> :ok
        group -> ensure_accounting!(group)
      end
    end
  end

  defp active_rooms(group_id),
    do:
      Repo.all(
        from r in Room,
          where: r.group_reservation_id == ^group_id and r.status == "active",
          order_by: r.position
      )

  defp room_outstanding(room) do
    cash =
      Repo.one(
        from a in CashAllocation,
          where: a.group_room_id == ^room.id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one(
        from a in CreditAllocation,
          where: a.group_room_id == ^room.id,
          select: coalesce(sum(a.amount_cents), 0)
      )

    max(room.deposit_due_cents - cash - credit, 0)
  end

  defp sync_group!(group, attrs \\ %{}) do
    rooms = active_rooms(group.id)
    lodging = Enum.sum_by(rooms, & &1.lodging_total_cents)
    due = Enum.sum_by(rooms, & &1.deposit_due_cents)
    cash = Enum.sum_by(rooms, fn room -> room_cash(room.id) end)
    credit = Enum.sum_by(rooms, fn room -> room_credit(room.id) end)

    update_group!(
      group,
      Map.merge(
        %{
          lodging_total_cents: lodging,
          deposit_due_cents: due,
          cash_paid_cents: cash,
          credit_paid_cents: credit,
          deposit_paid_cents: cash + credit
        },
        attrs
      )
    )
  end

  defp room_cash(room_id),
    do:
      Repo.one(
        from a in CashAllocation,
          where: a.group_room_id == ^room_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

  defp room_credit(room_id),
    do:
      Repo.one(
        from a in CreditAllocation,
          where: a.group_room_id == ^room_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

  defp held_cash(payment_id),
    do:
      Repo.one(
        from a in CashAllocation,
          where: a.cash_payment_id == ^payment_id,
          select: coalesce(sum(a.amount_cents), 0)
      )

  defp payment_json(payment) do
    %{
      "payment_operation_id" => payment.operation_id,
      "original_group_id" => Repo.get!(Group, payment.group_reservation_id).group_id,
      "recorded_cents" => payment.recorded_cents,
      "held_cents" => held_cash(payment.id),
      "refunded_cents" => payment.refunded_cents,
      "retained_cents" => payment.retained_cents,
      "converted_to_credit_cents" => payment.converted_to_credit_cents,
      "reduced_cents" => payment.reduced_cents,
      "charged_back_cents" => payment.charged_back_cents
    }
  end

  defp settlement_amounts(amount, true, "cash"), do: {amount, 0, 0}
  defp settlement_amounts(amount, true, "hotel_credit"), do: {0, 0, amount}
  defp settlement_amounts(amount, false, _method), do: {0, amount, 0}
  defp bonus_value(principal), do: principal + div(principal * 10 + 50, 100)
  defp legacy_payment?(payment), do: String.starts_with?(payment.operation_id, "__legacy__:")

  defp available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where:
          l.guest_id == ^guest_id and l.remaining_cents > 0 and l.issued_on <= ^on and
            l.expires_on >= ^on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp update_group!(group, attrs) do
    group |> Group.changeset(Map.put(attrs, :revision, group.revision + 1)) |> Repo.update!()
  end

  defp room_amounts(room, nights, rate_plan) do
    lodging = room["nightly_rate_cents"] * nights
    due = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

    %Room{
      room_id: room["room_id"],
      nightly_rate_cents: room["nightly_rate_cents"],
      lodging_total_cents: lodging,
      deposit_due_cents: due
    }
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          is_binary(id) and id != "" and is_integer(rate) and rate > 0

        _ ->
          false
      end)

    if valid and Enum.uniq_by(rooms, &Map.get(&1, "room_id")) == rooms,
      do: {:ok, rooms},
      else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}
  defp validate_identifier(value) when is_binary(value) and value != "", do: :ok
  defp validate_identifier(_value), do: {:error, "invalid_operation"}
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp validate_group_is_new(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id),
      do: {:error, "group_already_exists"},
      else: :ok
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}
  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on),
    do: if(Date.before?(booked_on, ~D[2027-01-01]), do: "flex-14", else: "flex-30")

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival}),
    do: Date.add(arrival, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival}),
    do: Date.add(arrival, -30)

  defp refundable_until(%Group{}), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> not Date.after?(occurred_on, deadline)
    end
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp parse_date(value, code) when is_binary(value),
    do:
      case(Date.from_iso8601(value),
        do: (
          {:ok, date} -> {:ok, date}
          _ -> {:error, code}
        )
      )

  defp parse_date(_value, code), do: {:error, code}

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding(%Group{}), do: 0
  defp reject(code, fields \\ %{}), do: {:error, Map.put(fields, "code", code)}
end
