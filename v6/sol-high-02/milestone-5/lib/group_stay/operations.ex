defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and exposes GroupStay's read models.

  Each operation owns its transaction. That deliberately makes a batch ordered but not atomic:
  a rejected operation cannot leak partial writes, while earlier applied operations remain visible.
  """

  import Ecto.Query

  alias GroupStay.Finance.{
    AllocationOrder,
    CashPayment,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Ledger,
    RoomCashAllocation,
    RoomCreditAllocation
  }

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @max_sqlite_integer 9_223_372_036_854_775_807
  @new_flexible_policy_date ~D[2027-01-01]

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, record.result}
    end
  end

  def get_operation(_operation_id), do: {:error, :operation_not_found}

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      %{operation_type: "record_cash_payment", result: %{"status" => "applied"}} ->
        case Repo.get(CashPayment, payment_operation_id) do
          nil -> {:error, :payment_not_reconcilable}
          payment -> {:ok, payment_view(payment)}
        end

      _record ->
        {:error, :payment_not_reconcilable}
    end
  end

  def get_payment(_payment_operation_id), do: {:error, :operation_not_found}

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group_view(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def ledger(on \\ nil) do
    with {:ok, as_of} <- as_of_date(on) do
      ledger = Repo.get!(Ledger, 1)

      {:ok,
       %{
         cash_held_cents: ledger.cash_held_cents,
         cash_refunded_cents: ledger.cash_refunded_cents,
         cash_retained_cents: ledger.cash_retained_cents,
         cash_converted_to_credit_cents: ledger.cash_converted_to_credit_cents,
         cash_reduced_cents: ledger.cash_reduced_cents,
         cash_charged_back_cents: ledger.cash_charged_back_cents,
         credit_liability_cents: credit_liability(as_of),
         credit_shortfall_cents: credit_shortfall()
       }}
    end
  end

  def guest_credit(guest_id, on \\ nil)

  def guest_credit(guest_id, on) when is_binary(guest_id) do
    with {:ok, as_of} <- as_of_date(on) do
      lots =
        available_lots_query(guest_id, as_of)
        |> Repo.all()
        |> Enum.map(fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)

      {:ok,
       %{
         guest_id: guest_id,
         available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
         lots: lots
       }}
    end
  end

  def guest_credit(guest_id, on), do: guest_credit(to_string(guest_id), on)

  defp credit_liability(as_of) do
    available =
      from(l in CreditLot,
        where: l.expires_on >= ^as_of and l.remaining_cents > 0,
        select: coalesce(sum(l.remaining_cents), 0)
      )
      |> Repo.one()

    applied =
      from(a in CreditAllocation,
        join: g in Group,
        on: g.group_id == a.group_id,
        where: g.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
      )
      |> Repo.one()

    available + applied
  end

  defp credit_shortfall do
    lots =
      from(l in CreditLot, where: l.unrecovered_clawback_cents > 0)
      |> Repo.all()

    Enum.sum(
      Enum.map(lots, fn lot ->
        applied =
          from(a in CreditAllocation,
            join: g in Group,
            on: g.group_id == a.group_id,
            where: a.credit_lot_id == ^lot.id and g.status == "active",
            select: coalesce(sum(a.amount_cents), 0)
          )
          |> Repo.one()

        min(lot.unrecovered_clawback_cents, applied)
      end)
    )
  end

  defp available_lots_query(guest_id, as_of) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^as_of and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp process_operation(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) and operation_id != "" do
    transact(fn ->
      case Repo.get_by(OperationRecord, operation_id: operation_id) do
        nil -> process_and_remember(operation)
        record -> replay_or_reject_conflict(operation, record)
      end
    end)
  end

  defp process_operation(operation) when is_map(operation) do
    process_new_operation(operation)
  end

  defp process_operation(_operation), do: rejected(%{}, "invalid_operation")

  defp process_and_remember(operation) do
    result = process_new_operation(operation)

    Repo.insert!(%OperationRecord{
      operation_id: operation["operation_id"],
      operation_type: operation_type(operation),
      submission: operation,
      result: result
    })

    result
  end

  defp replay_or_reject_conflict(operation, record) do
    if record.submission === operation do
      record.result
    else
      rejected(operation, "operation_id_conflict")
    end
  end

  defp process_new_operation(operation) do
    with :ok <- common_shape(operation) do
      case operation["type"] do
        "open_group" -> open_group(operation)
        "record_cash_payment" -> with_group(operation, &record_cash_payment/2)
        "apply_hotel_credit" -> with_group(operation, &apply_hotel_credit/2)
        "reschedule_group" -> with_group(operation, &reschedule_group/2)
        "cancel_group" -> with_group(operation, &cancel_group/2)
        "cancel_rooms" -> with_group(operation, &cancel_rooms/2)
        "transfer_deposit" -> transfer_deposit(operation)
        "reduce_cash_payment" -> with_payment(operation, :reduce)
        "charge_back_payment" -> with_payment(operation, :charge_back)
        _unknown -> rejected(operation, "invalid_operation")
      end
    else
      :error -> rejected(operation, "invalid_operation")
    end
  end

  defp common_shape(operation) do
    if valid_identifier?(operation["operation_id"]) and valid_identifier?(operation["type"]) and
         Map.has_key?(operation, "occurred_on") do
      :ok
    else
      :error
    end
  end

  defp open_group(operation) do
    required = ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      apply_open_group(operation)
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp apply_open_group(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.diff(departure_on, arrival_on) > 0 || {:error, "invalid_stay"},
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         nights = Date.diff(departure_on, arrival_on),
         {lodging_total, deposit_due} <- totals(rooms, nights, operation["rate_plan"]),
         true <-
           (lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer) ||
             {:error, "invalid_rooms"},
         attrs = %{
           group_id: operation["group_id"],
           guest_id: operation["guest_id"],
           property_id: operation["property_id"],
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: operation["rate_plan"],
           policy_version: policy_version(operation["rate_plan"], booked_on),
           status: "active",
           lodging_total_cents: lodging_total,
           deposit_due_cents: deposit_due,
           deposit_paid_cents: 0,
           cash_paid_cents: 0,
           credit_paid_cents: 0,
           revision: 1
         },
         {:ok, _group} <- insert_group(attrs),
         {_count, nil} <- insert_rooms(operation["group_id"], rooms) do
      applied(operation, %{
        group_id: operation["group_id"],
        deposit_due_cents: deposit_due,
        revision: 1
      })
    else
      {:error, code} when is_binary(code) -> rejected(operation, code)
      {:error, _date_error} -> rejected(operation, "invalid_stay")
    end
  end

  defp with_group(operation, apply_operation) do
    if valid_identifier?(operation["group_id"]) do
      case Repo.get(Group, operation["group_id"]) do
        nil -> rejected(operation, "group_not_found")
        group -> check_revision_then_apply(operation, group, apply_operation)
      end
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp check_revision_then_apply(operation, group, apply_operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      rejected(operation, "stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    else
      apply_operation.(operation, group)
    end
  end

  defp transfer_deposit(operation) do
    source_group_id = operation["source_group_id"]
    destination_group_id = operation["destination_group_id"]

    if valid_identifier?(source_group_id) and valid_identifier?(destination_group_id) do
      case Repo.get(Group, source_group_id) do
        nil ->
          rejected(operation, "group_not_found", %{group_id: source_group_id})

        source ->
          case Repo.get(Group, destination_group_id) do
            nil ->
              rejected(operation, "group_not_found", %{group_id: destination_group_id})

            destination ->
              check_transfer_revisions_then_apply(operation, source, destination)
          end
      end
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp check_transfer_revisions_then_apply(operation, source, destination) do
    cond do
      Map.has_key?(operation, "expected_revision") and
          operation["expected_revision"] != source.revision ->
        stale_revision(operation, source, operation["expected_revision"])

      Map.has_key?(operation, "destination_expected_revision") and
          operation["destination_expected_revision"] != destination.revision ->
        stale_revision(operation, destination, operation["destination_expected_revision"])

      true ->
        apply_transfer_deposit(operation, source, destination)
    end
  end

  defp stale_revision(operation, group, expected_revision) do
    rejected(operation, "stale_revision", %{
      group_id: group.group_id,
      expected_revision: expected_revision,
      actual_revision: group.revision
    })
  end

  defp apply_transfer_deposit(operation, source, destination) do
    amount = operation["amount_cents"]

    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation, "invalid_operation")

      not valid_date?(operation["occurred_on"]) ->
        rejected(operation, "invalid_operation")

      source.status != "active" ->
        rejected(operation, "group_not_active", %{group_id: source.group_id})

      destination.status != "active" ->
        rejected(operation, "group_not_active", %{group_id: destination.group_id})

      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        rejected(operation, "invalid_transfer")

      not (is_integer(amount) and amount > 0) ->
        rejected(operation, "invalid_amount")

      amount > held_funding(source.group_id) ->
        rejected(operation, "transfer_exceeds_held_funding")

      amount > outstanding(destination) ->
        rejected(operation, "transfer_exceeds_outstanding")

      true ->
        chunks = draw_transfer_chunks(source.group_id, amount)
        allocate_transfer_chunks(destination.group_id, operation["operation_id"], chunks)

        cash = sum_transfer_chunks(chunks, :cash)
        credit = sum_transfer_chunks(chunks, :credit)

        move_group_credit_allocations(source.group_id, destination.group_id, chunks)
        mark_transferred_payments(chunks)
        update_groups_for_transfer(source.group_id, destination.group_id, cash, credit)

        applied(operation, %{
          source_group_id: source.group_id,
          destination_group_id: destination.group_id,
          amount_cents: amount,
          source_outstanding_deposit_cents: outstanding(source) + amount,
          destination_outstanding_deposit_cents: outstanding(destination) - amount,
          source_revision: source.revision + 1,
          destination_revision: destination.revision + 1
        })
    end
  end

  defp record_cash_payment(operation, group) do
    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation, "invalid_operation")

      not valid_date?(operation["occurred_on"]) ->
        rejected(operation, "invalid_operation")

      group.status != "active" ->
        rejected(operation, "group_not_active")

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        rejected(operation, "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        rejected(operation, "payment_exceeds_outstanding")

      true ->
        amount = operation["amount_cents"]
        revision = group.revision + 1

        Repo.insert!(%CashPayment{
          payment_operation_id: operation["operation_id"],
          group_id: group.group_id,
          recorded_cents: amount,
          held_cents: amount
        })

        allocate_cash_to_rooms(group.group_id, operation["operation_id"], amount)

        {1, nil} =
          from(g in Group, where: g.group_id == ^group.group_id)
          |> Repo.update_all(
            inc: [deposit_paid_cents: amount, cash_paid_cents: amount, revision: 1]
          )

        {1, nil} =
          from(l in Ledger, where: l.id == 1)
          |> Repo.update_all(inc: [cash_held_cents: amount])

        applied(operation, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group) - amount,
          revision: revision
        })
    end
  end

  defp apply_hotel_credit(operation, group) do
    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation, "invalid_operation")

      not valid_date?(operation["occurred_on"]) ->
        rejected(operation, "invalid_operation")

      group.status != "active" ->
        rejected(operation, "group_not_active")

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        rejected(operation, "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        rejected(operation, "payment_exceeds_outstanding")

      true ->
        {:ok, occurred_on} = parse_date(operation["occurred_on"])
        amount = operation["amount_cents"]
        lots = Repo.all(available_lots_query(group.guest_id, occurred_on))

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
          rejected(operation, "insufficient_credit")
        else
          chunks = consume_credit_lots(group.group_id, lots, amount)
          allocate_credit_to_rooms(group.group_id, operation["operation_id"], chunks)

          {1, nil} =
            from(g in Group, where: g.group_id == ^group.group_id)
            |> Repo.update_all(
              inc: [deposit_paid_cents: amount, credit_paid_cents: amount, revision: 1]
            )

          applied(operation, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(group) - amount,
            revision: group.revision + 1
          })
        end
    end
  end

  defp consume_credit_lots(group_id, lots, requested_amount) do
    {_remaining, chunks} =
      Enum.reduce_while(lots, {requested_amount, []}, fn lot, {remaining, chunks} ->
        consumed = min(lot.remaining_cents, remaining)

        {1, nil} =
          from(l in CreditLot, where: l.id == ^lot.id)
          |> Repo.update_all(inc: [remaining_cents: -consumed])

        case Repo.get_by(CreditAllocation, group_id: group_id, credit_lot_id: lot.id) do
          nil ->
            Repo.insert!(%CreditAllocation{
              group_id: group_id,
              credit_lot_id: lot.id,
              amount_cents: consumed
            })

          allocation ->
            from(a in CreditAllocation, where: a.id == ^allocation.id)
            |> Repo.update_all(inc: [amount_cents: consumed])
        end

        next = {remaining - consumed, [{lot.id, consumed} | chunks]}
        if consumed == remaining, do: {:halt, next}, else: {:cont, next}
      end)

    Enum.reverse(chunks)
  end

  defp reschedule_group(operation, group) do
    cond do
      not Map.has_key?(operation, "new_arrival_on") ->
        rejected(operation, "invalid_operation")

      group.status != "active" ->
        rejected(operation, "group_not_active")

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
             true <- Date.compare(new_arrival, occurred_on) == :gt || {:error, "invalid_stay"} do
          stay_length = Date.diff(group.departure_on, group.arrival_on)
          new_departure = Date.add(new_arrival, stay_length)
          revision = group.revision + 1

          {1, nil} =
            from(g in Group, where: g.group_id == ^group.group_id)
            |> Repo.update_all(
              set: [arrival_on: new_arrival, departure_on: new_departure],
              inc: [revision: 1]
            )

          applied(operation, %{
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival),
            new_departure_on: Date.to_iso8601(new_departure),
            policy_version: group_policy_version(group),
            refundable_until:
              refundable_until(group_policy_version(group), new_arrival)
              |> date_or_nil(),
            revision: revision
          })
        else
          {:error, _reason} -> rejected(operation, "invalid_stay")
        end
    end
  end

  defp cancel_group(operation, group) do
    cond do
      group.status != "active" ->
        rejected(operation, "group_not_active")

      Map.get(operation, "refund_method", "cash") not in ["cash", "hotel_credit"] ->
        rejected(operation, "invalid_operation")

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} ->
            refund_method = Map.get(operation, "refund_method", "cash")
            refundable = refundable?(group, occurred_on)

            if refund_method == "hotel_credit" and not refundable do
              rejected(operation, "refund_method_not_available")
            else
              rooms = active_rooms(group.group_id)
              settle_rooms(operation, group, rooms, occurred_on, refundable, refund_method)
            end

          {:error, _reason} ->
            rejected(operation, "invalid_operation")
        end
    end
  end

  defp cancel_rooms(operation, group) do
    room_ids = operation["room_ids"]

    cond do
      not Map.has_key?(operation, "room_ids") ->
        rejected(operation, "invalid_operation")

      not (is_list(room_ids) and room_ids != [] and Enum.all?(room_ids, &valid_identifier?/1) and
               Enum.uniq(room_ids) == room_ids) ->
        rejected(operation, "invalid_rooms")

      Map.get(operation, "refund_method", "cash") not in ["cash", "hotel_credit"] ->
        rejected(operation, "invalid_operation")

      true ->
        rooms =
          from(r in Room,
            where:
              r.group_id == ^group.group_id and r.status == "active" and r.room_id in ^room_ids,
            order_by: r.position
          )
          |> Repo.all()

        if length(rooms) != length(room_ids) do
          rejected(operation, "invalid_rooms")
        else
          case parse_date(operation["occurred_on"]) do
            {:ok, occurred_on} ->
              refund_method = Map.get(operation, "refund_method", "cash")
              refundable = refundable?(group, occurred_on)

              if refund_method == "hotel_credit" and not refundable do
                rejected(operation, "refund_method_not_available")
              else
                settle_rooms(operation, group, rooms, occurred_on, refundable, refund_method,
                  cancelled_room_ids: Enum.map(rooms, & &1.room_id)
                )
              end

            {:error, _reason} ->
              rejected(operation, "invalid_operation")
          end
        end
    end
  end

  defp settle_rooms(operation, group, rooms, occurred_on, refundable, refund_method, extra \\ []) do
    room_database_ids = Enum.map(rooms, & &1.id)

    cash_allocations =
      from(a in RoomCashAllocation,
        where: a.room_id in ^room_database_ids,
        order_by: [asc: a.allocation_order, asc: a.id],
        select: {a, a.allocation_order}
      )
      |> Repo.all()

    credit_allocations =
      from(a in RoomCreditAllocation, where: a.room_id in ^room_database_ids, order_by: a.id)
      |> Repo.all()

    cash =
      Enum.sum(Enum.map(cash_allocations, fn {allocation, _order} -> allocation.amount_cents end))

    credit = Enum.sum(Enum.map(credit_allocations, & &1.amount_cents))
    refunded = if refundable and refund_method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash

    credit_issued =
      if refundable and refund_method == "hotel_credit",
        do: bonus_value(cash),
        else: 0

    settle_cash_payments(cash_allocations, refundable, refund_method)
    settle_room_credit(group.group_id, credit_allocations, occurred_on, refundable)

    if credit_issued > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation["operation_id"],
          remaining_cents: credit_issued,
          expires_on: Date.add(occurred_on, 365),
          unrecovered_clawback_cents: 0
        })

      create_entitlements(lot.id, cash_contributors(cash_allocations))
    end

    {_, nil} =
      from(a in RoomCashAllocation, where: a.room_id in ^room_database_ids)
      |> Repo.delete_all()

    {_, nil} =
      from(a in RoomCreditAllocation, where: a.room_id in ^room_database_ids)
      |> Repo.delete_all()

    {_, nil} =
      from(r in Room, where: r.id in ^room_database_ids)
      |> Repo.update_all(set: [status: "cancelled"])

    lodging = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
    due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

    active_remaining =
      from(r in Room,
        where:
          r.group_id == ^group.group_id and r.status == "active" and
            r.id not in ^room_database_ids,
        select: count(r.id)
      )
      |> Repo.one()

    next_status = if active_remaining == 0, do: "cancelled", else: "active"

    {1, nil} =
      from(g in Group, where: g.group_id == ^group.group_id)
      |> Repo.update_all(
        set: [status: next_status],
        inc: [
          lodging_total_cents: -lodging,
          deposit_due_cents: -due,
          deposit_paid_cents: -(cash + credit),
          cash_paid_cents: -cash,
          credit_paid_cents: -credit,
          revision: 1
        ]
      )

    {1, nil} =
      from(l in Ledger, where: l.id == 1)
      |> Repo.update_all(
        inc: [
          cash_held_cents: -cash,
          cash_refunded_cents: refunded,
          cash_retained_cents: retained,
          cash_converted_to_credit_cents:
            if(refundable and refund_method == "hotel_credit", do: cash, else: 0)
        ]
      )

    fields = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: group.revision + 1
    }

    applied(operation, Map.merge(fields, Map.new(extra)))
  end

  defp settle_cash_payments(allocations, refundable, refund_method) do
    disposition =
      cond do
        not refundable -> :retained_cents
        refund_method == "hotel_credit" -> :converted_to_credit_cents
        true -> :refunded_cents
      end

    allocations
    |> Enum.map(fn {allocation, _order} -> allocation end)
    |> Enum.reject(&is_nil(&1.payment_operation_id))
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.each(fn {payment_operation_id, payment_allocations} ->
      amount = Enum.sum(Enum.map(payment_allocations, & &1.amount_cents))

      from(p in CashPayment, where: p.payment_operation_id == ^payment_operation_id)
      |> Repo.update_all(inc: [held_cents: -amount] ++ [{disposition, amount}])
    end)
  end

  defp settle_room_credit(group_id, allocations, occurred_on, refundable) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, lot_allocations} ->
      amount = Enum.sum(Enum.map(lot_allocations, & &1.amount_cents))
      if refundable, do: restore_credit(lot_id, amount, occurred_on)
      reduce_group_credit_allocation(group_id, lot_id, amount)
    end)
  end

  defp restore_credit(lot_id, amount, occurred_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    excess = amount - absorbed
    restored = if Date.compare(lot.expires_on, occurred_on) == :lt, do: 0, else: excess

    from(l in CreditLot, where: l.id == ^lot_id)
    |> Repo.update_all(
      inc: [
        unrecovered_clawback_cents: -absorbed,
        remaining_cents: restored
      ]
    )
  end

  defp reduce_group_credit_allocation(group_id, lot_id, amount) do
    allocation = Repo.get_by!(CreditAllocation, group_id: group_id, credit_lot_id: lot_id)

    if allocation.amount_cents == amount do
      Repo.delete!(allocation)
    else
      from(a in CreditAllocation, where: a.id == ^allocation.id)
      |> Repo.update_all(inc: [amount_cents: -amount])
    end
  end

  defp cash_contributors(cash_allocations) do
    Enum.map(cash_allocations, fn {allocation, _order} ->
      %{
        payment_operation_id: allocation.payment_operation_id,
        amount: allocation.amount_cents
      }
    end)
  end

  defp create_entitlements(lot_id, contributors) do
    Enum.reduce(contributors, 0, fn contributor, running_principal ->
      entitlement =
        bonus_value(running_principal + contributor.amount) - bonus_value(running_principal)

      Repo.insert!(%CreditEntitlement{
        credit_lot_id: lot_id,
        payment_operation_id: contributor.payment_operation_id,
        principal_cents: contributor.amount,
        entitlement_cents: entitlement
      })

      running_principal + contributor.amount
    end)
  end

  defp with_payment(operation, action) do
    payment_operation_id = operation["payment_operation_id"]

    if valid_identifier?(payment_operation_id) do
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil ->
          rejected(operation, "operation_not_found")

        %{operation_type: "record_cash_payment", result: %{"status" => "applied"}} ->
          payment = Repo.get(CashPayment, payment_operation_id)

          if payment do
            group = Repo.get!(Group, payment.group_id)

            check_revision_then_apply(operation, group, fn operation, group ->
              case action do
                :reduce -> reduce_cash_payment(operation, group, payment)
                :charge_back -> charge_back_payment(operation, group, payment)
              end
            end)
          else
            rejected(operation, payment_error(action))
          end

        _record ->
          rejected(operation, payment_error(action))
      end
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp payment_error(:reduce), do: "payment_not_reducible"
  defp payment_error(:charge_back), do: "payment_not_chargeable"

  defp reduce_cash_payment(operation, group, payment) do
    amount = operation["amount_cents"]

    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation, "invalid_operation")

      not valid_date?(operation["occurred_on"]) ->
        rejected(operation, "invalid_operation")

      payment.held_cents <= 0 ->
        rejected(operation, "payment_not_reducible")

      not (is_integer(amount) and amount > 0) ->
        rejected(operation, "invalid_amount")

      amount > payment.held_cents ->
        rejected(operation, "reduction_exceeds_held_cash")

      true ->
        removed_by_group = remove_held_allocations(payment.payment_operation_id, amount)

        from(p in CashPayment, where: p.payment_operation_id == ^payment.payment_operation_id)
        |> Repo.update_all(inc: [held_cents: -amount, reduced_cents: amount])

        update_groups_for_removed_cash(group.group_id, removed_by_group)

        from(l in Ledger, where: l.id == 1)
        |> Repo.update_all(inc: [cash_held_cents: -amount, cash_reduced_cents: amount])

        applied(operation, %{
          payment_operation_id: payment.payment_operation_id,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents:
            outstanding_after_removed_cash(group, Map.get(removed_by_group, group.group_id, 0)),
          revision: group.revision + 1
        })
    end
  end

  defp charge_back_payment(operation, group, payment) do
    remaining = payment.recorded_cents - payment.reduced_cents

    cond do
      not valid_date?(operation["occurred_on"]) ->
        rejected(operation, "invalid_operation")

      remaining <= 0 or payment.charged_back_cents > 0 ->
        rejected(operation, "payment_not_chargeable")

      true ->
        removed_by_group =
          remove_held_allocations(payment.payment_operation_id, payment.held_cents)

        revoke_credit_entitlements(payment.payment_operation_id)

        from(p in CashPayment, where: p.payment_operation_id == ^payment.payment_operation_id)
        |> Repo.update_all(
          set: [
            held_cents: 0,
            refunded_cents: 0,
            retained_cents: 0,
            converted_to_credit_cents: 0
          ],
          inc: [charged_back_cents: remaining]
        )

        update_groups_for_removed_cash(group.group_id, removed_by_group)

        from(l in Ledger, where: l.id == 1)
        |> Repo.update_all(
          inc: [
            cash_held_cents: -payment.held_cents,
            cash_refunded_cents: -payment.refunded_cents,
            cash_retained_cents: -payment.retained_cents,
            cash_converted_to_credit_cents: -payment.converted_to_credit_cents,
            cash_charged_back_cents: remaining
          ]
        )

        applied(operation, %{
          payment_operation_id: payment.payment_operation_id,
          group_id: group.group_id,
          charged_back_cents: remaining,
          outstanding_deposit_cents:
            outstanding_after_removed_cash(group, Map.get(removed_by_group, group.group_id, 0)),
          revision: group.revision + 1
        })
    end
  end

  defp remove_held_allocations(_payment_operation_id, 0), do: %{}

  defp remove_held_allocations(payment_operation_id, amount) do
    allocations =
      from(a in RoomCashAllocation,
        where: a.payment_operation_id == ^payment_operation_id,
        order_by: [desc: a.allocation_order, desc: a.id]
      )
      |> Repo.all()

    {remaining, removed_by_group} =
      Enum.reduce_while(allocations, {amount, %{}}, fn allocation,
                                                       {remaining, removed_by_group} ->
        removed = min(allocation.amount_cents, remaining)

        if removed == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          from(a in RoomCashAllocation, where: a.id == ^allocation.id)
          |> Repo.update_all(inc: [amount_cents: -removed])
        end

        next =
          {remaining - removed,
           Map.update(removed_by_group, allocation.group_id, removed, &(&1 + removed))}

        if removed == remaining, do: {:halt, next}, else: {:cont, next}
      end)

    if remaining != 0, do: raise("cash payment allocation invariant violated")
    removed_by_group
  end

  defp revoke_credit_entitlements(payment_operation_id) do
    from(e in CreditEntitlement,
      where: e.payment_operation_id == ^payment_operation_id,
      order_by: e.id
    )
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removable = min(lot.remaining_cents, entitlement.entitlement_cents)
      unrecovered = entitlement.entitlement_cents - removable

      from(l in CreditLot, where: l.id == ^lot.id)
      |> Repo.update_all(
        inc: [remaining_cents: -removable, unrecovered_clawback_cents: unrecovered]
      )
    end)
  end

  defp update_groups_for_removed_cash(addressed_group_id, removed_by_group) do
    affected_group_ids =
      removed_by_group
      |> Map.keys()
      |> Kernel.++([addressed_group_id])
      |> Enum.uniq()

    Enum.each(affected_group_ids, fn group_id ->
      amount = Map.get(removed_by_group, group_id, 0)

      from(g in Group, where: g.group_id == ^group_id)
      |> Repo.update_all(
        inc: [deposit_paid_cents: -amount, cash_paid_cents: -amount, revision: 1]
      )
    end)
  end

  defp outstanding_after_removed_cash(%Group{status: "active"} = group, amount) do
    min(group.deposit_due_cents, outstanding(group) + amount)
  end

  defp outstanding_after_removed_cash(%Group{}, _amount), do: 0

  defp active_rooms(group_id) do
    from(r in Room,
      where: r.group_id == ^group_id and r.status == "active",
      order_by: r.position
    )
    |> Repo.all()
  end

  defp held_funding(group_id) do
    cash =
      from(a in RoomCashAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        where: a.group_id == ^group_id and r.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
      )
      |> Repo.one()

    credit =
      from(a in RoomCreditAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        where: a.group_id == ^group_id and r.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
      )
      |> Repo.one()

    cash + credit
  end

  defp draw_transfer_chunks(group_id, amount) do
    cash_allocations =
      from(a in RoomCashAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        where: a.group_id == ^group_id and r.status == "active"
      )
      |> Repo.all()
      |> Enum.map(&%{kind: :cash, allocation: &1})

    credit_allocations =
      from(a in RoomCreditAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        where: a.group_id == ^group_id and r.status == "active"
      )
      |> Repo.all()
      |> Enum.map(&%{kind: :credit, allocation: &1})

    allocations =
      (cash_allocations ++ credit_allocations)
      |> Enum.sort_by(& &1.allocation.allocation_order, :desc)

    {remaining, chunks} =
      Enum.reduce_while(allocations, {amount, []}, fn item, {remaining, chunks} ->
        drawn = min(item.allocation.amount_cents, remaining)
        reduce_room_allocation(item.kind, item.allocation, drawn)

        chunk =
          case item.kind do
            :cash ->
              %{
                kind: :cash,
                amount_cents: drawn,
                payment_operation_id: item.allocation.payment_operation_id
              }

            :credit ->
              %{
                kind: :credit,
                amount_cents: drawn,
                credit_lot_id: item.allocation.credit_lot_id
              }
          end

        next = {remaining - drawn, [chunk | chunks]}
        if drawn == remaining, do: {:halt, next}, else: {:cont, next}
      end)

    if remaining != 0, do: raise("transfer allocation invariant violated")
    Enum.reverse(chunks)
  end

  defp reduce_room_allocation(kind, allocation, amount) do
    schema = if kind == :cash, do: RoomCashAllocation, else: RoomCreditAllocation

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      from(a in schema, where: a.id == ^allocation.id)
      |> Repo.update_all(inc: [amount_cents: -amount])
    end
  end

  defp allocate_transfer_chunks(group_id, funding_operation_id, chunks) do
    Enum.each(chunks, fn
      %{kind: :cash, payment_operation_id: payment_operation_id, amount_cents: amount} ->
        allocate_cash_to_rooms(group_id, payment_operation_id, funding_operation_id, amount)

      %{kind: :credit, credit_lot_id: lot_id, amount_cents: amount} ->
        allocate_credit_to_rooms(group_id, funding_operation_id, [{lot_id, amount}])
    end)
  end

  defp move_group_credit_allocations(source_group_id, destination_group_id, chunks) do
    chunks
    |> Enum.filter(&(&1.kind == :credit))
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, lot_chunks} ->
      amount = Enum.sum(Enum.map(lot_chunks, & &1.amount_cents))
      reduce_group_credit_allocation(source_group_id, lot_id, amount)
      increase_group_credit_allocation(destination_group_id, lot_id, amount)
    end)
  end

  defp increase_group_credit_allocation(group_id, lot_id, amount) do
    case Repo.get_by(CreditAllocation, group_id: group_id, credit_lot_id: lot_id) do
      nil ->
        Repo.insert!(%CreditAllocation{
          group_id: group_id,
          credit_lot_id: lot_id,
          amount_cents: amount
        })

      allocation ->
        from(a in CreditAllocation, where: a.id == ^allocation.id)
        |> Repo.update_all(inc: [amount_cents: amount])
    end
  end

  defp mark_transferred_payments(chunks) do
    payment_operation_ids =
      chunks
      |> Enum.filter(&(&1.kind == :cash and not is_nil(&1.payment_operation_id)))
      |> Enum.map(& &1.payment_operation_id)
      |> Enum.uniq()

    if payment_operation_ids != [] do
      from(p in CashPayment, where: p.payment_operation_id in ^payment_operation_ids)
      |> Repo.update_all(set: [participated_in_transfer: true])
    end
  end

  defp update_groups_for_transfer(source_group_id, destination_group_id, cash, credit) do
    total = cash + credit

    from(g in Group, where: g.group_id == ^source_group_id)
    |> Repo.update_all(
      inc: [
        deposit_paid_cents: -total,
        cash_paid_cents: -cash,
        credit_paid_cents: -credit,
        revision: 1
      ]
    )

    from(g in Group, where: g.group_id == ^destination_group_id)
    |> Repo.update_all(
      inc: [
        deposit_paid_cents: total,
        cash_paid_cents: cash,
        credit_paid_cents: credit,
        revision: 1
      ]
    )
  end

  defp sum_transfer_chunks(chunks, kind) do
    chunks
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  defp allocate_cash_to_rooms(group_id, payment_operation_id, amount) do
    allocate_cash_to_rooms(group_id, payment_operation_id, payment_operation_id, amount)
  end

  defp allocate_cash_to_rooms(
         group_id,
         payment_operation_id,
         funding_operation_id,
         amount
       ) do
    allocate_to_rooms(group_id, [{payment_operation_id, amount}], fn room,
                                                                     payment_id,
                                                                     allocated ->
      Repo.insert!(%RoomCashAllocation{
        group_id: group_id,
        room_id: room.id,
        payment_operation_id: payment_id,
        funding_operation_id: funding_operation_id,
        amount_cents: allocated,
        allocation_order: next_allocation_order()
      })
    end)
  end

  defp allocate_credit_to_rooms(group_id, funding_operation_id, chunks) do
    allocate_to_rooms(group_id, chunks, fn room, lot_id, allocated ->
      Repo.insert!(%RoomCreditAllocation{
        group_id: group_id,
        room_id: room.id,
        credit_lot_id: lot_id,
        funding_operation_id: funding_operation_id,
        amount_cents: allocated,
        allocation_order: next_allocation_order()
      })
    end)
  end

  defp next_allocation_order do
    Repo.insert!(%AllocationOrder{}).id
  end

  defp allocate_to_rooms(group_id, chunks, inserter) do
    rooms =
      active_rooms(group_id)
      |> Enum.map(fn room ->
        cash =
          from(a in RoomCashAllocation,
            where: a.room_id == ^room.id,
            select: coalesce(sum(a.amount_cents), 0)
          )
          |> Repo.one()

        credit =
          from(a in RoomCreditAllocation,
            where: a.room_id == ^room.id,
            select: coalesce(sum(a.amount_cents), 0)
          )
          |> Repo.one()

        %{room: room, funded: cash + credit}
      end)

    {_rooms, unallocated} =
      Enum.reduce(chunks, {rooms, 0}, fn {source, amount}, {room_state, _previous} ->
        {updated, remaining} =
          Enum.map_reduce(room_state, amount, fn state, remaining ->
            capacity = state.room.deposit_due_cents - state.funded
            allocated = min(max(capacity, 0), remaining)
            if allocated > 0, do: inserter.(state.room, source, allocated)
            {%{state | funded: state.funded + allocated}, remaining - allocated}
          end)

        {updated, remaining}
      end)

    if unallocated != 0, do: raise("funding allocation exceeded active room deposits")
    :ok
  end

  defp insert_group(attrs) do
    case attrs |> Group.create_changeset() |> Repo.insert() do
      {:ok, group} -> {:ok, group}
      {:error, _changeset} -> {:error, "group_already_exists"}
    end
  end

  defp insert_rooms(group_id, rooms) do
    group = Repo.get!(Group, group_id)
    nights = Date.diff(group.departure_on, group.arrival_on)

    rows =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          group_id: group_id,
          position: position,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"],
          status: "active",
          lodging_total_cents: nights * room["nightly_rate_cents"],
          deposit_due_cents: room_deposit(nights * room["nightly_rate_cents"], group.rate_plan)
        }
      end)

    Repo.insert_all(Room, rows)
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 ->
          true

        _room ->
          false
      end)

    if valid? do
      room_ids = Enum.map(rooms, & &1["room_id"])

      if Enum.uniq(room_ids) == room_ids do
        {:ok, rooms}
      else
        {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp totals(rooms, nights, rate_plan) do
    Enum.reduce(rooms, {0, 0}, fn room, {lodging_total, deposit_total} ->
      lodging = nights * room["nightly_rate_cents"]
      deposit = room_deposit(lodging, rate_plan)
      {lodging_total + lodging, deposit_total + deposit}
    end)
  end

  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp group_view(group) do
    rooms =
      from(r in Room, where: r.group_id == ^group.group_id, order_by: r.position)
      |> Repo.all()
      |> Enum.map(fn room ->
        cash =
          from(a in RoomCashAllocation,
            where: a.room_id == ^room.id,
            select: coalesce(sum(a.amount_cents), 0)
          )
          |> Repo.one()

        credit =
          from(a in RoomCreditAllocation,
            where: a.room_id == ^room.id,
            select: coalesce(sum(a.amount_cents), 0)
          )
          |> Repo.one()

        %{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status: room.status,
          deposit_due_cents: room.deposit_due_cents,
          cash_paid_cents: cash,
          credit_paid_cents: credit
        }
      end)

    policy_version = group_policy_version(group)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version,
      refundable_until: refundable_until(policy_version, group.arrival_on) |> date_or_nil(),
      status: group.status,
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp payment_view(payment) do
    statement = %{
      payment_operation_id: payment.payment_operation_id,
      original_group_id: payment.group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: payment.held_cents,
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_to_credit_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }

    if payment.participated_in_transfer do
      Map.put(statement, :held_by_group, held_cash_by_group(payment.payment_operation_id))
    else
      statement
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    from(a in RoomCashAllocation,
      where: a.payment_operation_id == ^payment_operation_id,
      group_by: a.group_id,
      order_by: a.group_id,
      select: %{group_id: a.group_id, amount_cents: sum(a.amount_cents)}
    )
    |> Repo.all()
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @new_flexible_policy_date) == :lt, do: "flex-14", else: "flex-30"
  end

  defp group_policy_version(%Group{policy_version: nil} = group) do
    policy_version(group.rate_plan, group.booked_on)
  end

  defp group_policy_version(%Group{policy_version: policy_version}), do: policy_version

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until("advance-nonrefundable", _arrival_on), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group_policy_version(group), group.arrival_on) do
      nil -> false
      last_refundable_date -> Date.compare(occurred_on, last_refundable_date) != :gt
    end
  end

  defp date_or_nil(nil), do: nil
  defp date_or_nil(date), do: Date.to_iso8601(date)

  defp round_percent(amount, percent), do: div(amount * percent + 50, 100)
  defp bonus_value(amount), do: amount + round_percent(amount, 10)

  defp outstanding(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding(%Group{}), do: 0

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_date}

  defp as_of_date(nil), do: {:ok, Date.utc_today()}
  defp as_of_date(value), do: parse_date(value)

  defp valid_date?(value), do: match?({:ok, _date}, parse_date(value))

  defp transact(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp rejected(operation, code, extra \\ %{}) do
    Map.merge(
      %{
        operation_id: Map.get(operation, "operation_id"),
        status: "rejected",
        code: code
      },
      extra
    )
  end

  defp applied(operation, fields) do
    Map.merge(%{operation_id: operation["operation_id"], status: "applied"}, fields)
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp valid_identifier?(value), do: is_binary(value) and value != ""
end
