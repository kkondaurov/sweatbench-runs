defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Groups.{
    CashAllocation,
    ConversionContribution,
    CreditAllocation,
    CreditLot,
    Group,
    PaymentDisposition,
    Room
  }

  alias GroupStay.Operations.PartnerOperation
  alias GroupStay.Repo

  @sqlite_max_integer 9_223_372_036_854_775_807

  def open_group(attrs) do
    transact(fn ->
      if Repo.get_by(Group, group_id: attrs.group_id) do
        {:error, :group_already_exists}
      else
        with {:ok, totals} <- opening_totals(attrs),
             policy_version = policy_version(attrs.rate_plan, attrs.booked_on),
             {:ok, group} <- insert_group(Map.put(attrs, :policy_version, policy_version), totals) do
          insert_rooms(group, totals.rooms)

          {:ok,
           %{
             group_id: group.group_id,
             deposit_due_cents: group.deposit_due_cents,
             revision: group.revision
           }}
        end
      end
    end)
  end

  def record_cash_payment(group_id, amount_cents, expected_revision, operation_id) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           :ok <- valid_payment_amount(amount_cents),
           :ok <- within_outstanding(amount_cents, outstanding_deposit(group)) do
        payment =
          Repo.insert!(%PaymentDisposition{
            payment_operation_id: operation_id,
            group_id: group.id,
            recorded_cents: amount_cents
          })

        allocate_cash(group, payment, amount_cents)
        group = update_active_totals(group, revision: group.revision + 1)

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding_deposit(group),
           revision: group.revision
         }}
      end
    end)
  end

  def reschedule_group(group_id, occurred_on, new_arrival_value, expected_revision) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           {:ok, new_arrival_on} <- parse_stay_date(new_arrival_value),
           :ok <- future_arrival(new_arrival_on, occurred_on) do
        shift = Date.diff(new_arrival_on, group.arrival_on)

        group =
          group
          |> Ecto.Changeset.change(
            arrival_on: new_arrival_on,
            departure_on: Date.add(group.departure_on, shift),
            revision: group.revision + 1
          )
          |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           new_arrival_on: group.arrival_on,
           new_departure_on: group.departure_on,
           policy_version: effective_policy_version(group),
           refundable_until: refundable_until(group),
           revision: group.revision
         }}
      end
    end)
  end

  def cancel_group(group_id, occurred_on, expected_revision, refund_method, operation_id) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           rooms <- active_rooms(group),
           {:ok, settlement} <-
             settle_rooms(group, rooms, occurred_on, refund_method, operation_id) do
        group = finish_room_cancellation(group, rooms, settlement)

        {:ok,
         %{
           group_id: group.group_id,
           refunded_cents: settlement.refunded_cents,
           retained_cents: settlement.retained_cents,
           credit_issued_cents: settlement.credit_issued_cents,
           revision: group.revision
         }}
      end
    end)
  end

  def cancel_rooms(
        group_id,
        room_ids,
        occurred_on,
        expected_revision,
        refund_method,
        operation_id
      ) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           {:ok, rooms} <- selected_active_rooms(group, room_ids),
           {:ok, settlement} <-
             settle_rooms(group, rooms, occurred_on, refund_method, operation_id) do
        group = finish_room_cancellation(group, rooms, settlement)

        {:ok,
         %{
           group_id: group.group_id,
           cancelled_room_ids: Enum.map(rooms, & &1.room_id),
           refunded_cents: settlement.refunded_cents,
           retained_cents: settlement.retained_cents,
           credit_issued_cents: settlement.credit_issued_cents,
           revision: group.revision
         }}
      end
    end)
  end

  def apply_hotel_credit(group_id, amount_cents, occurred_on, expected_revision, operation_id) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           :ok <- valid_payment_amount(amount_cents),
           :ok <- within_outstanding(amount_cents, outstanding_deposit(group)),
           lots <- available_credit_lots(group.guest_id, occurred_on),
           :ok <- enough_credit(lots, amount_cents) do
        consume_and_allocate_credit(lots, group, amount_cents, operation_id)
        group = update_active_totals(group, revision: group.revision + 1)

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding_deposit(group),
           revision: group.revision
         }}
      end
    end)
  end

  def reduce_cash_payment(payment_operation_id, amount_cents, expected_revision) do
    transact(fn ->
      with {:ok, operation} <- durable_operation(payment_operation_id),
           {:ok, payment} <- reducible_payment(operation),
           group = Repo.get!(Group, payment.group_id),
           :ok <- current_payment_revision(group, expected_revision),
           :ok <- valid_payment_amount(amount_cents),
           held <- payment_held(payment),
           :ok <- reducible_held(held),
           :ok <- within_reducible(amount_cents, held) do
        remove_payment_allocations(payment, amount_cents)

        payment
        |> Ecto.Changeset.change(reduced_cents: payment.reduced_cents + amount_cents)
        |> Repo.update!()

        group = update_active_totals(group, revision: group.revision + 1)

        {:ok,
         %{
           payment_operation_id: payment_operation_id,
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding_deposit(group),
           revision: group.revision
         }}
      end
    end)
  end

  def charge_back_payment(payment_operation_id, expected_revision) do
    transact(fn ->
      with {:ok, operation} <- durable_operation(payment_operation_id),
           {:ok, payment} <- chargeable_payment(operation),
           group = Repo.get!(Group, payment.group_id),
           :ok <- current_payment_revision(group, expected_revision) do
        held = payment_held(payment)
        charged_back = payment.recorded_cents - payment.reduced_cents

        remove_payment_allocations(payment, held)
        revoke_converted_credit(payment)

        group =
          group
          |> Ecto.Changeset.change(
            cash_refunded_cents: group.cash_refunded_cents - payment.refunded_cents,
            cash_retained_cents: group.cash_retained_cents - payment.retained_cents,
            cash_converted_to_credit_cents:
              group.cash_converted_to_credit_cents - payment.converted_cents
          )
          |> Repo.update!()
          |> update_active_totals(revision: group.revision + 1)

        payment
        |> Ecto.Changeset.change(
          refunded_cents: 0,
          retained_cents: 0,
          converted_cents: 0,
          charged_back_cents: charged_back
        )
        |> Repo.update!()

        {:ok,
         %{
           payment_operation_id: payment_operation_id,
           group_id: group.group_id,
           charged_back_cents: charged_back,
           outstanding_deposit_cents: outstanding_deposit(group),
           revision: group.revision
         }}
      end
    end)
  end

  def payment_statement(payment_operation_id) do
    Repo.transaction(fn ->
      case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
        nil -> {:error, :operation_not_found}
        operation -> payment_statement_for(operation)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:error, :group_not_found}

      group ->
        rooms = rooms(group)
        totals = sum_active_rooms(rooms)

        {:ok,
         %{
           group_id: group.group_id,
           guest_id: group.guest_id,
           property_id: group.property_id,
           revision: group.revision,
           booked_on: group.booked_on,
           arrival_on: group.arrival_on,
           departure_on: group.departure_on,
           rate_plan: group.rate_plan,
           policy_version: effective_policy_version(group),
           refundable_until: refundable_until(group),
           status: group.status,
           rooms:
             Enum.map(rooms, fn room ->
               %{
                 room_id: room.room_id,
                 nightly_rate_cents: room.nightly_rate_cents,
                 status: room.status,
                 deposit_due_cents: room.deposit_due_cents,
                 cash_paid_cents: room.cash_paid_cents,
                 credit_paid_cents: room.credit_paid_cents
               }
             end),
           lodging_total_cents: totals.lodging,
           deposit_due_cents: totals.due,
           deposit_paid_cents: totals.cash + totals.credit,
           cash_paid_cents: totals.cash,
           credit_paid_cents: totals.credit,
           outstanding_deposit_cents: totals.due - totals.cash - totals.credit
         }}
    end
  end

  def ledger(on \\ Date.utc_today()) do
    group_totals =
      Repo.one(
        from group in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    group.status,
                    group.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(group.cash_converted_to_credit_cents), 0)
          }
      )

    payment_totals =
      Repo.one(
        from payment in PaymentDisposition,
          select: %{
            cash_reduced_cents: coalesce(sum(payment.reduced_cents), 0),
            cash_charged_back_cents: coalesce(sum(payment.charged_back_cents), 0)
          }
      )

    available_liability =
      Repo.one(
        from lot in CreditLot,
          where: lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    allocated_liability =
      Repo.one(
        from allocation in CreditAllocation, select: coalesce(sum(allocation.amount_cents), 0)
      )

    shortfall =
      Repo.all(from lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)
      |> Enum.reduce(0, fn lot, total ->
        applied =
          Repo.one(
            from allocation in CreditAllocation,
              where: allocation.credit_lot_id == ^lot.id,
              select: coalesce(sum(allocation.amount_cents), 0)
          )

        total + min(lot.unrecovered_clawback_cents, applied)
      end)

    %{
      data:
        group_totals
        |> Map.merge(payment_totals)
        |> Map.put(:credit_liability_cents, available_liability + allocated_liability)
        |> Map.put(:credit_shortfall_cents, shortfall)
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = available_credit_lots(guest_id, on)

    %{
      data: %{
        guest_id: guest_id,
        available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
        lots:
          Enum.map(lots, fn lot ->
            %{
              source_operation_id: lot.source_operation_id,
              remaining_cents: lot.remaining_cents,
              expires_on: lot.expires_on
            }
          end)
      }
    }
  end

  defp settle_rooms(group, rooms, occurred_on, refund_method, operation_id) do
    refundable = refundable?(group, occurred_on)

    with :ok <- valid_refund_method(refund_method, refundable) do
      room_ids = Enum.map(rooms, & &1.id)

      cash_allocations =
        Repo.all(
          from allocation in CashAllocation,
            where: allocation.room_id in ^room_ids,
            order_by: allocation.id,
            preload: [:payment_disposition]
        )

      cash = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
      classify_cash_allocations(cash_allocations, refundable, refund_method)
      Repo.delete_all(from allocation in CashAllocation, where: allocation.room_id in ^room_ids)

      {refunded, retained, converted, issued} =
        settle_cash_amount(
          group,
          cash_allocations,
          cash,
          refundable,
          refund_method,
          operation_id,
          occurred_on
        )

      settle_allocated_credit(room_ids, refundable, occurred_on)

      {:ok,
       %{
         refunded_cents: refunded,
         retained_cents: retained,
         converted_cents: converted,
         credit_issued_cents: issued
       }}
    end
  end

  defp settle_cash_amount(_group, _allocations, cash, true, "cash", _operation_id, _on),
    do: {cash, 0, 0, 0}

  defp settle_cash_amount(group, allocations, cash, true, "hotel_credit", operation_id, on) do
    issued = with_bonus(cash)

    if issued > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: issued,
          expires_on: Date.add(on, 365)
        })

      insert_conversion_contributions(lot, allocations)
    end

    {0, 0, cash, issued}
  end

  defp settle_cash_amount(_group, _allocations, cash, false, "cash", _operation_id, _on),
    do: {0, cash, 0, 0}

  defp classify_cash_allocations(allocations, refundable, refund_method) do
    field =
      cond do
        refundable and refund_method == "cash" -> :refunded_cents
        refundable and refund_method == "hotel_credit" -> :converted_cents
        true -> :retained_cents
      end

    allocations
    |> Enum.reject(&is_nil(&1.payment_disposition_id))
    |> Enum.group_by(& &1.payment_disposition)
    |> Enum.each(fn {payment, entries} ->
      amount = Enum.sum(Enum.map(entries, & &1.amount_cents))

      payment
      |> Ecto.Changeset.change([{field, Map.fetch!(payment, field) + amount}])
      |> Repo.update!()
    end)
  end

  defp insert_conversion_contributions(lot, allocations) do
    contributions =
      allocations
      |> Enum.chunk_by(& &1.payment_disposition_id)
      |> Enum.map(fn entries ->
        {hd(entries).payment_disposition_id, Enum.sum(Enum.map(entries, & &1.amount_cents))}
      end)

    {_running, _position} =
      Enum.reduce(contributions, {0, 0}, fn {payment_id, principal}, {running, position} ->
        entitlement = with_bonus(running + principal) - with_bonus(running)

        Repo.insert!(%ConversionContribution{
          credit_lot_id: lot.id,
          payment_disposition_id: payment_id,
          principal_cents: principal,
          entitlement_cents: entitlement,
          position: position
        })

        {running + principal, position + 1}
      end)
  end

  defp finish_room_cancellation(group, rooms, settlement) do
    Enum.each(rooms, fn room ->
      room
      |> Ecto.Changeset.change(
        status: "cancelled",
        cash_paid_cents: 0,
        credit_paid_cents: 0
      )
      |> Repo.update!()
    end)

    remaining =
      Repo.aggregate(
        from(room in Room, where: room.group_id == ^group.id and room.status == "active"),
        :count
      )

    group =
      group
      |> Ecto.Changeset.change(
        status: if(remaining == 0, do: "cancelled", else: "active"),
        cash_refunded_cents: group.cash_refunded_cents + settlement.refunded_cents,
        cash_retained_cents: group.cash_retained_cents + settlement.retained_cents,
        cash_converted_to_credit_cents:
          group.cash_converted_to_credit_cents + settlement.converted_cents
      )
      |> Repo.update!()

    update_active_totals(group, revision: group.revision + 1)
  end

  defp settle_allocated_credit(room_ids, refundable, occurred_on) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.room_id in ^room_ids,
          order_by: [allocation.inserted_at, allocation.position],
          preload: [:credit_lot]
      )

    Enum.each(allocations, fn allocation ->
      if refundable,
        do: restore_credit(allocation.credit_lot, allocation.amount_cents, occurred_on)

      Repo.delete!(allocation)
    end)
  end

  defp restore_credit(lot, amount, occurred_on) do
    lot = Repo.get!(CreditLot, lot.id)
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    available = amount - absorbed

    lot
    |> Ecto.Changeset.change(
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
      remaining_cents:
        lot.remaining_cents +
          if(Date.compare(lot.expires_on, occurred_on) in [:gt, :eq], do: available, else: 0)
    )
    |> Repo.update!()
  end

  defp allocate_cash(group, payment, amount) do
    allocate_to_rooms(group, amount, fn room, applied, _position ->
      Repo.insert!(%CashAllocation{
        room_id: room.id,
        payment_disposition_id: payment.id,
        amount_cents: applied
      })

      room
      |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents + applied)
      |> Repo.update!()
    end)
  end

  defp consume_and_allocate_credit(lots, group, amount, operation_id) do
    portions = consume_credit_lots(lots, amount, [])
    position = :erlang.unique_integer([:positive, :monotonic])

    Enum.reduce(portions, 0, fn {lot, portion}, offset ->
      allocate_to_rooms(group, portion, fn room, applied, room_offset ->
        Repo.insert!(%CreditAllocation{
          credit_lot_id: lot.id,
          group_id: group.id,
          room_id: room.id,
          application_operation_id: operation_id,
          position: position + offset + room_offset,
          amount_cents: applied
        })

        room
        |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents + applied)
        |> Repo.update!()
      end)

      offset + 1
    end)
  end

  defp consume_credit_lots(_lots, 0, acc), do: Enum.reverse(acc)

  defp consume_credit_lots([lot | lots], amount, acc) do
    consumed = min(lot.remaining_cents, amount)

    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - consumed)
    |> Repo.update!()

    consume_credit_lots(lots, amount - consumed, [{lot, consumed} | acc])
  end

  defp allocate_to_rooms(group, amount, insert) do
    {_remaining, _position} =
      Enum.reduce_while(active_rooms(group), {amount, 0}, fn room, {remaining, position} ->
        outstanding = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        applied = min(remaining, outstanding)
        if applied > 0, do: insert.(room, applied, position)
        next = remaining - applied
        if next == 0, do: {:halt, {0, position + 1}}, else: {:cont, {next, position + 1}}
      end)
  end

  defp remove_payment_allocations(_payment, 0), do: :ok

  defp remove_payment_allocations(payment, amount) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.payment_disposition_id == ^payment.id,
          order_by: [desc: allocation.id],
          preload: [:room]
      )

    Enum.reduce_while(allocations, amount, fn allocation, remaining ->
      removed = min(allocation.amount_cents, remaining)

      allocation.room
      |> Ecto.Changeset.change(cash_paid_cents: allocation.room.cash_paid_cents - removed)
      |> Repo.update!()

      if removed == allocation.amount_cents do
        Repo.delete!(allocation)
      else
        allocation
        |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - removed)
        |> Repo.update!()
      end

      next = remaining - removed
      if next == 0, do: {:halt, 0}, else: {:cont, next}
    end)
  end

  defp revoke_converted_credit(payment) do
    Repo.all(
      from contribution in ConversionContribution,
        where: contribution.payment_disposition_id == ^payment.id,
        preload: [:credit_lot]
    )
    |> Enum.each(fn contribution ->
      lot = contribution.credit_lot
      revoked = min(lot.remaining_cents, contribution.entitlement_cents)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - revoked,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + contribution.entitlement_cents - revoked
      )
      |> Repo.update!()
    end)
  end

  defp payment_statement_for(
         %PartnerOperation{
           operation_type: "record_cash_payment",
           result: %{"status" => "applied"}
         } = operation
       ) do
    case Repo.get_by(PaymentDisposition, payment_operation_id: operation.operation_id) do
      nil ->
        {:error, :payment_not_reconcilable}

      payment ->
        {:ok,
         %{
           payment_operation_id: payment.payment_operation_id,
           original_group_id: Repo.get!(Group, payment.group_id).group_id,
           recorded_cents: payment.recorded_cents,
           held_cents: payment_held(payment),
           refunded_cents: payment.refunded_cents,
           retained_cents: payment.retained_cents,
           converted_to_credit_cents: payment.converted_cents,
           reduced_cents: payment.reduced_cents,
           charged_back_cents: payment.charged_back_cents
         }}
    end
  end

  defp payment_statement_for(_operation), do: {:error, :payment_not_reconcilable}

  defp durable_operation(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> {:ok, operation}
    end
  end

  defp reducible_payment(
         %PartnerOperation{
           operation_type: "record_cash_payment",
           result: %{"status" => "applied"}
         } = operation
       ) do
    case Repo.get_by(PaymentDisposition, payment_operation_id: operation.operation_id) do
      nil -> {:error, :payment_not_reducible}
      payment -> {:ok, payment}
    end
  end

  defp reducible_payment(_operation), do: {:error, :payment_not_reducible}

  defp chargeable_payment(
         %PartnerOperation{
           operation_type: "record_cash_payment",
           result: %{"status" => "applied"}
         } = operation
       ) do
    case Repo.get_by(PaymentDisposition, payment_operation_id: operation.operation_id) do
      %PaymentDisposition{charged_back_cents: charged} when charged > 0 ->
        {:error, :payment_not_chargeable}

      %PaymentDisposition{} = payment when payment.reduced_cents == payment.recorded_cents ->
        {:error, :payment_not_chargeable}

      %PaymentDisposition{} = payment ->
        {:ok, payment}

      nil ->
        {:error, :payment_not_chargeable}
    end
  end

  defp chargeable_payment(_operation), do: {:error, :payment_not_chargeable}

  defp payment_held(payment) do
    Repo.one(
      from allocation in CashAllocation,
        where: allocation.payment_disposition_id == ^payment.id,
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp reducible_held(held) when held > 0, do: :ok
  defp reducible_held(_held), do: {:error, :payment_not_reducible}
  defp within_reducible(amount, held) when amount <= held, do: :ok
  defp within_reducible(_amount, _held), do: {:error, :reduction_exceeds_held_cash}

  defp selected_active_rooms(group, room_ids) when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &usable_identifier?/1) and
         length(Enum.uniq(room_ids)) == length(room_ids) do
      selected =
        Repo.all(
          from room in Room,
            where:
              room.group_id == ^group.id and room.room_id in ^room_ids and room.status == "active",
            order_by: room.position
        )

      if length(selected) == length(room_ids), do: {:ok, selected}, else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp selected_active_rooms(_group, _room_ids), do: {:error, :invalid_rooms}

  defp update_active_totals(group, extra) do
    totals = sum_active_rooms(active_rooms(group))

    group
    |> Ecto.Changeset.change(
      Keyword.merge(
        [
          lodging_total_cents: totals.lodging,
          deposit_due_cents: totals.due,
          cash_paid_cents: totals.cash,
          credit_paid_cents: totals.credit
        ],
        extra
      )
    )
    |> Repo.update!()
  end

  defp sum_active_rooms(rooms) do
    Enum.reduce(rooms, %{lodging: 0, due: 0, cash: 0, credit: 0}, fn room, total ->
      if room.status == "active" do
        %{
          lodging: total.lodging + room.lodging_total_cents,
          due: total.due + room.deposit_due_cents,
          cash: total.cash + room.cash_paid_cents,
          credit: total.credit + room.credit_paid_cents
        }
      else
        total
      end
    end)
  end

  defp rooms(group),
    do: Repo.all(from room in Room, where: room.group_id == ^group.id, order_by: room.position)

  defp active_rooms(group),
    do:
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.id and room.status == "active",
          order_by: room.position
      )

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on),
    do: if(Date.before?(booked_on, ~D[2027-01-01]), do: "flex-14", else: "flex-30")

  defp effective_policy_version(%{policy_version: nil} = group),
    do: policy_version(group.rate_plan, group.booked_on)

  defp effective_policy_version(group), do: group.policy_version

  defp refundable_until(group) do
    case effective_policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      cutoff -> Date.compare(occurred_on, cutoff) in [:lt, :eq]
    end
  end

  defp valid_refund_method("cash", _refundable), do: :ok
  defp valid_refund_method("hotel_credit", true), do: :ok
  defp valid_refund_method(_method, _refundable), do: {:error, :refund_method_not_available}

  defp available_credit_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
    )
  end

  defp enough_credit(lots, amount) do
    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount,
      do: :ok,
      else: {:error, :insufficient_credit}
  end

  defp outstanding_deposit(group),
    do: group.deposit_due_cents - group.cash_paid_cents - group.credit_paid_cents

  defp opening_totals(attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    cond do
      nights < 1 -> {:error, :invalid_stay}
      attrs.rate_plan not in ["flexible", "advance_purchase"] -> {:error, :invalid_rate_plan}
      not valid_rooms?(attrs.rooms) -> {:error, :invalid_rooms}
      true -> calculate_room_totals(attrs, nights)
    end
  end

  defp calculate_room_totals(attrs, nights) do
    rooms =
      Enum.map(attrs.rooms, fn room ->
        lodging = room.nightly_rate_cents * nights
        due = if attrs.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        Map.merge(room, %{lodging_total_cents: lodging, deposit_due_cents: due})
      end)

    lodging = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
    due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

    if lodging <= @sqlite_max_integer and due <= @sqlite_max_integer,
      do: {:ok, %{lodging_total_cents: lodging, deposit_due_cents: due, rooms: rooms}},
      else: {:error, :invalid_rooms}
  end

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn room ->
      usable_identifier?(room.room_id) and is_integer(room.nightly_rate_cents) and
        room.nightly_rate_cents > 0 and room.nightly_rate_cents <= @sqlite_max_integer
    end) and Enum.uniq_by(rooms, & &1.room_id) == rooms
  end

  defp valid_rooms?(_rooms), do: false

  defp insert_group(attrs, totals) do
    attrs
    |> Map.merge(Map.take(totals, [:lodging_total_cents, :deposit_due_cents]))
    |> Map.merge(%{status: "active", revision: 1})
    |> Group.create_changeset()
    |> Repo.insert()
    |> case do
      {:ok, group} -> {:ok, group}
      {:error, %{errors: [group_id: {_message, _options}]}} -> {:error, :group_already_exists}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_rooms(group, rooms) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entries =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          id: Ecto.UUID.generate(),
          group_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          status: "active",
          lodging_total_cents: room.lodging_total_cents,
          deposit_due_cents: room.deposit_due_cents,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all(Room, entries)
    if count != length(entries), do: Repo.rollback(:invalid_rooms)
  end

  defp existing_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp current_revision(_group, :any), do: :ok
  defp current_revision(%{revision: revision}, revision), do: :ok

  defp current_revision(group, expected),
    do: {:error, {:stale_revision, expected, group.revision}}

  defp current_payment_revision(group, expected) do
    case current_revision(group, expected) do
      :ok ->
        :ok

      {:error, {:stale_revision, expected, actual}} ->
        {:error, {:stale_payment_revision, group.group_id, expected, actual}}
    end
  end

  defp active(%{status: "active"}), do: :ok
  defp active(_group), do: {:error, :group_not_active}
  defp valid_payment_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp valid_payment_amount(_amount), do: {:error, :invalid_amount}
  defp within_outstanding(amount, outstanding) when amount <= outstanding, do: :ok
  defp within_outstanding(_amount, _outstanding), do: {:error, :payment_exceeds_outstanding}

  defp future_arrival(arrival, occurred_on),
    do: if(Date.after?(arrival, occurred_on), do: :ok, else: {:error, :invalid_stay})

  defp parse_stay_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> {:error, :invalid_stay}
    end
  end

  defp parse_stay_date(_value), do: {:error, :invalid_stay}
  defp usable_identifier?(value), do: is_binary(value) and String.trim(value) != ""
  defp with_bonus(cash), do: cash + div(cash * 10 + 50, 100)

  defp transact(fun) do
    if Repo.in_transaction?() do
      fun.()
    else
      case Repo.transaction(fun, mode: :immediate) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
