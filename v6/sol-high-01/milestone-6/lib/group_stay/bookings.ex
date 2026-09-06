defmodule GroupStay.Bookings do
  @moduledoc """
  Applies durable partner operations and exposes room-level group-deposit accounting.

  Each operation runs in its own immediate transaction so its audit result and accounting
  effects commit together. Operations in a batch are deliberately processed serially.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Bookings.{
    CashPayment,
    CashPaymentDisposition,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    PartnerOperation,
    Room,
    RoomFundingAllocation
  }

  alias GroupStay.Repo
  alias GroupStay.Finance

  @rate_plans ~w(flexible advance_purchase)
  @known_operations ~w(open_group record_cash_payment reschedule_group cancel_group
                       apply_hotel_credit cancel_rooms reduce_cash_payment charge_back_payment
                       transfer_deposit start_finance_reporting)
  @new_flexible_policy_on ~D[2027-01-01]

  def apply_batch(operations) when is_list(operations),
    do: Enum.map(operations, &apply_operation/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :error
      _group -> {:ok, load_group(group_id)}
    end
  end

  def get_group(_group_id), do: :error

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> :error
      operation -> {:ok, operation.result}
    end
  end

  def get_operation(_operation_id), do: :error

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        :not_found

      _operation ->
        case Repo.get(CashPayment, payment_operation_id) do
          nil -> :not_reconcilable
          payment -> {:ok, payment_data(payment)}
        end
    end
  end

  def get_payment(_payment_operation_id), do: :not_found

  def group_data(group) do
    policy_version = group.policy_version || policy_version(group.rate_plan, group.booked_on)
    active_rooms = Enum.filter(group.rooms, &(&1.status == "active"))
    lodging = sum(active_rooms, :lodging_total_cents)
    due = sum(active_rooms, :deposit_due_cents)
    cash = sum(active_rooms, :cash_paid_cents)
    credit = sum(active_rooms, :credit_paid_cents)
    paid = cash + credit

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
      refundable_until: iso_date(refundable_until(policy_version, group.arrival_on)),
      status: group.status,
      rooms: Enum.map(group.rooms, &room_data/1),
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      deposit_paid_cents: paid,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      outstanding_deposit_cents: max(due - paid, 0)
    }
  end

  def ledger_data(on \\ nil) do
    with {:ok, on} <- read_date(on) do
      groups = Repo.all(Group)

      cash_totals =
        groups
        |> Enum.reduce(empty_cash_totals(), fn group, totals ->
          totals
          |> Map.update!(:cash_refunded_cents, &(&1 + group.cash_refunded_cents))
          |> Map.update!(:cash_retained_cents, &(&1 + group.cash_retained_cents))
          |> Map.update!(
            :cash_converted_to_credit_cents,
            &(&1 + group.cash_converted_to_credit_cents)
          )
          |> Map.update!(:cash_reduced_cents, &(&1 + group.cash_reduced_cents))
          |> Map.update!(:cash_charged_back_cents, &(&1 + group.cash_charged_back_cents))
        end)

      held =
        Repo.one(
          from room in Room,
            where: room.status == "active",
            select: coalesce(sum(room.cash_paid_cents), 0)
        )

      available_credit =
        Repo.one(
          from lot in CreditLot,
            where: lot.remaining_cents > 0 and lot.issued_on <= ^on and lot.expires_on >= ^on,
            select: coalesce(sum(lot.remaining_cents), 0)
        )

      applied_by_lot = active_credit_by_lot()
      applied_credit = applied_by_lot |> Map.values() |> Enum.sum()

      shortfall =
        Repo.all(from lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)
        |> Enum.reduce(0, fn lot, total ->
          total + min(lot.unrecovered_clawback_cents, Map.get(applied_by_lot, lot.id, 0))
        end)

      {:ok,
       cash_totals
       |> Map.put(:cash_held_cents, held)
       |> Map.put(:credit_liability_cents, available_credit + applied_credit)
       |> Map.put(:credit_shortfall_cents, shortfall)}
    end
  end

  def credit_data(guest_id, on \\ nil) when is_binary(guest_id) do
    with {:ok, on} <- read_date(on) do
      lots =
        Repo.all(
          from lot in CreditLot,
            where:
              lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^on and
                lot.expires_on >= ^on,
            order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
        )

      {:ok,
       %{
         guest_id: guest_id,
         available_cents: sum(lots, :remaining_cents),
         lots:
           Enum.map(lots, fn lot ->
             %{
               source_operation_id: lot.source_operation_id,
               remaining_cents: lot.remaining_cents,
               expires_on: Date.to_iso8601(lot.expires_on)
             }
           end)
       }}
    end
  end

  def daily_finance_report(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> Finance.daily_report(date)
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  def daily_finance_report(_date), do: {:error, :invalid_reporting_date}

  defp apply_operation(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id),
       do: transact(fn -> apply_idempotently(operation) end)

  defp apply_operation(operation), do: rejected(operation_id(operation), "invalid_operation")

  defp apply_idempotently(operation) do
    operation_id = operation_id(operation)

    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        result = operation |> process_new_operation() |> json_data()

        Repo.insert!(%PartnerOperation{
          operation_id: operation_id,
          operation_type: submitted_type(operation),
          submission: operation,
          result: result
        })

        result

      stored ->
        if stored.submission === operation,
          do: stored.result,
          else: rejected(operation_id, "operation_id_conflict")
    end
  end

  defp process_new_operation(operation) do
    type = Map.get(operation, "type")

    if type in @known_operations and structurally_complete?(type, operation) do
      case execute(type, operation) do
        {:ok, result} -> result
        {:error, result} -> result
      end
    else
      rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp transact(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp execute("open_group", operation), do: open_group(operation)
  defp execute("record_cash_payment", operation), do: record_cash_payment(operation)
  defp execute("apply_hotel_credit", operation), do: apply_hotel_credit(operation)
  defp execute("reschedule_group", operation), do: reschedule_group(operation)
  defp execute("cancel_group", operation), do: cancel_group(operation)
  defp execute("cancel_rooms", operation), do: cancel_rooms(operation)
  defp execute("reduce_cash_payment", operation), do: reduce_cash_payment(operation)
  defp execute("charge_back_payment", operation), do: charge_back_payment(operation)
  defp execute("transfer_deposit", operation), do: transfer_deposit(operation)
  defp execute("start_finance_reporting", operation), do: start_finance_reporting(operation)

  defp start_finance_reporting(operation) do
    with {:ok, starts_on} <- parse_date(operation["starts_on"], "invalid_reporting_date"),
         :ok <- Finance.start(starts_on) do
      applied(operation, %{starts_on: Date.to_iso8601(starts_on)})
    else
      {:error, :already_started} -> domain_error(operation, "reporting_already_started")
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp open_group(operation) do
    with :ok <- validate_identifiers(operation, ~w(group_id guest_id property_id)),
         {:ok, booked_on} <- parse_date(operation["occurred_on"], "invalid_stay"),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(operation["departure_on"], "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         :ok <- ensure_group_absent(operation["group_id"]) do
      nights = Date.diff(departure_on, arrival_on)

      room_rows =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          lodging = nights * room.nightly_rate_cents

          %{
            group_id: operation["group_id"],
            position: position,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: "active",
            lodging_total_cents: lodging,
            deposit_due_cents: room_deposit(lodging, operation["rate_plan"]),
            cash_paid_cents: 0,
            credit_paid_cents: 0
          }
        end)

      lodging = sum(room_rows, :lodging_total_cents)
      due = sum(room_rows, :deposit_due_cents)

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
        lodging_total_cents: lodging,
        deposit_due_cents: due,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        cash_reduced_cents: 0,
        cash_charged_back_cents: 0,
        revision: 1
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          {_count, nil} = Repo.insert_all(Room, room_rows)

          applied(operation, %{
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          })

        {:error, _changeset} ->
          domain_error(operation, "group_already_exists")
      end
    else
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp record_cash_payment(operation) do
    with :ok <- validate_identifiers(operation, ~w(group_id)),
         {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         :ok <- validate_amount(operation["amount_cents"]),
         :ok <- ensure_not_overpaid(group, operation["amount_cents"]) do
      amount = operation["amount_cents"]
      allocate_cash(group.group_id, amount, operation_id(operation), operation_id(operation))

      Repo.insert!(%CashPayment{
        payment_operation_id: operation_id(operation),
        original_group_id: group.group_id,
        recorded_cents: amount,
        held_cents: amount
      })

      group = update_group_funding(group, amount, 0)

      Finance.record_cash(operation_id(operation), occurred_on, %{
        group.property_id => %{received_cents: amount}
      })

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp apply_hotel_credit(operation) do
    with :ok <- validate_identifiers(operation, ~w(group_id)),
         {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         :ok <- validate_amount(operation["amount_cents"]),
         :ok <- ensure_not_overpaid(group, operation["amount_cents"]),
         {:ok, lots} <-
           credit_lots_for_application(group.guest_id, operation["amount_cents"], occurred_on) do
      amount = operation["amount_cents"]
      chunks = consume_credit_lots(lots, group.group_id, amount, occurred_on)
      allocate_credit(group.group_id, chunks, operation_id(operation))
      group = update_group_funding(group, 0, amount)

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp transfer_deposit(operation) do
    with :ok <- validate_identifiers(operation, ~w(source_group_id destination_group_id)),
         {:ok, source} <- fetch_group_by_id(operation, operation["source_group_id"]),
         {:ok, destination} <- fetch_group_by_id(operation, operation["destination_group_id"]),
         :ok <- check_revision(source, operation),
         :ok <- check_destination_revision(destination, operation),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         :ok <- validate_transfer_groups(source, destination),
         :ok <- ensure_transfer_active(source, operation),
         :ok <- ensure_transfer_active(destination, operation),
         :ok <- validate_amount(operation["amount_cents"]),
         :ok <- ensure_transfer_funding(source, operation["amount_cents"]),
         :ok <- ensure_transfer_capacity(destination, operation["amount_cents"]) do
      amount = operation["amount_cents"]
      chunks = draw_transfer_chunks(source.group_id, amount)
      Enum.each(chunks, &allocate_transfer_chunk(destination.group_id, &1))

      cash =
        chunks
        |> Enum.filter(&(&1.funding_type == "cash"))
        |> Enum.sum_by(& &1.amount)

      transfer_movements =
        %{}
        |> add_cash_movement(source.property_id, :transferred_out_cents, cash)
        |> add_cash_movement(destination.property_id, :transferred_in_cents, cash)

      Finance.record_cash(
        operation_id(operation),
        occurred_on,
        transfer_movements
      )

      source =
        source
        |> sync_group_active_totals(revision: source.revision + 1)

      destination =
        destination
        |> sync_group_active_totals(revision: destination.revision + 1)

      applied(operation, %{
        source_group_id: source.group_id,
        destination_group_id: destination.group_id,
        amount_cents: amount,
        source_outstanding_deposit_cents: outstanding_deposit(source),
        destination_outstanding_deposit_cents: outstanding_deposit(destination),
        source_revision: source.revision,
        destination_revision: destination.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp reschedule_group(operation) do
    with :ok <- validate_identifiers(operation, ~w(group_id)),
         {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_stay"),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"], "invalid_stay"),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)

      group =
        group
        |> change(
          arrival_on: new_arrival_on,
          departure_on: Date.add(group.departure_on, shift),
          revision: group.revision + 1
        )
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(group.arrival_on),
        new_departure_on: Date.to_iso8601(group.departure_on),
        policy_version: group.policy_version,
        refundable_until: iso_date(refundable_until(group.policy_version, group.arrival_on)),
        revision: group.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp cancel_group(operation) do
    with :ok <- validate_identifiers(operation, ~w(group_id)),
         {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         {:ok, refund_method} <- validate_refund_method(operation),
         refundable? = refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(refund_method, refundable?) do
      {group, settlement} =
        settle_rooms(
          group,
          active_rooms(group.group_id),
          refundable?,
          refund_method,
          occurred_on,
          operation
        )

      applied(operation, %{
        group_id: group.group_id,
        refunded_cents: settlement.refunded,
        retained_cents: settlement.retained,
        credit_issued_cents: settlement.credit_issued,
        revision: group.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp cancel_rooms(operation) do
    with :ok <- validate_identifiers(operation, ~w(group_id)),
         {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, rooms} <- selected_active_rooms(group.group_id, operation["room_ids"]),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         {:ok, refund_method} <- validate_refund_method(operation),
         refundable? = refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(refund_method, refundable?) do
      {group, settlement} =
        settle_rooms(group, rooms, refundable?, refund_method, occurred_on, operation)

      applied(operation, %{
        group_id: group.group_id,
        cancelled_room_ids: Enum.map(rooms, & &1.room_id),
        refunded_cents: settlement.refunded,
        retained_cents: settlement.retained,
        credit_issued_cents: settlement.credit_issued,
        revision: group.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp reduce_cash_payment(operation) do
    with :ok <- validate_identifiers(operation, ~w(payment_operation_id)),
         {:ok, payment} <- target_payment(operation, "payment_not_reducible"),
         group = Repo.get!(Group, payment.original_group_id),
         :ok <- check_revision(group, operation),
         :ok <- ensure_payment_held(payment, "payment_not_reducible"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         :ok <- validate_amount(operation["amount_cents"]),
         :ok <- ensure_reduction_within_held(payment, operation["amount_cents"]) do
      amount = operation["amount_cents"]
      removed_by_group = remove_held_cash(payment.payment_operation_id, amount)

      payment
      |> change(
        held_cents: payment.held_cents - amount,
        reduced_cents: payment.reduced_cents + amount
      )
      |> Repo.update!()

      groups =
        removed_by_group
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.put(group.group_id)
        |> Enum.reduce(%{}, fn group_id, groups ->
          changed_group = Repo.get!(Group, group_id)

          extra_changes =
            if group_id == group.group_id,
              do: [cash_reduced_cents: changed_group.cash_reduced_cents + amount],
              else: []

          changed_group =
            sync_group_active_totals(
              changed_group,
              Keyword.put(extra_changes, :revision, changed_group.revision + 1)
            )

          Map.put(groups, group_id, changed_group)
        end)

      group = Map.fetch!(groups, group.group_id)

      Finance.record_cash(
        operation_id(operation),
        occurred_on,
        cash_movements_for_groups(removed_by_group, :reduced_cents)
      )

      applied(operation, %{
        payment_operation_id: payment.payment_operation_id,
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp charge_back_payment(operation) do
    with :ok <- validate_identifiers(operation, ~w(payment_operation_id)),
         {:ok, payment} <- target_payment(operation, "payment_not_chargeable"),
         group = Repo.get!(Group, payment.original_group_id),
         :ok <- check_revision(group, operation),
         :ok <- ensure_chargeable(payment),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation") do
      ensure_payment_entitlements(payment)
      held_by_group = remove_held_cash(payment.payment_operation_id, payment.held_cents)
      settled_by_group = payment_dispositions_by_group(payment.payment_operation_id)
      revoked = revoke_payment_entitlements(payment.payment_operation_id, occurred_on)

      charged = payment.recorded_cents - payment.reduced_cents

      payment
      |> change(
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: charged
      )
      |> Repo.update!()

      group_ids =
        held_by_group
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.union(MapSet.new(Map.keys(settled_by_group)))
        |> MapSet.put(group.group_id)

      groups =
        Enum.reduce(group_ids, %{}, fn group_id, groups ->
          changed_group = Repo.get!(Group, group_id)

          dispositions =
            Map.get(settled_by_group, group_id, %{
              refunded_cents: 0,
              retained_cents: 0,
              converted_to_credit_cents: 0
            })

          changed_group =
            sync_group_active_totals(changed_group,
              cash_refunded_cents:
                changed_group.cash_refunded_cents - dispositions.refunded_cents,
              cash_retained_cents:
                changed_group.cash_retained_cents - dispositions.retained_cents,
              cash_converted_to_credit_cents:
                changed_group.cash_converted_to_credit_cents -
                  dispositions.converted_to_credit_cents,
              cash_charged_back_cents:
                changed_group.cash_charged_back_cents +
                  if(group_id == group.group_id, do: charged, else: 0),
              revision: changed_group.revision + 1
            )

          Map.put(groups, group_id, changed_group)
        end)

      Repo.delete_all(
        from disposition in CashPaymentDisposition,
          where: disposition.payment_operation_id == ^payment.payment_operation_id
      )

      group = Map.fetch!(groups, group.group_id)

      cash_movements =
        held_by_group
        |> cash_movements_for_groups(:charged_back_cents)
        |> add_settlement_reversals(settled_by_group)

      Finance.record_cash(operation_id(operation), occurred_on, cash_movements)
      Finance.record_credit(operation_id(operation), occurred_on, %{revoked_cents: revoked})

      applied(operation, %{
        payment_operation_id: payment.payment_operation_id,
        group_id: group.group_id,
        charged_back_cents: charged,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, result} when is_map(result) -> {:error, result}
      {:error, code} -> domain_error(operation, code)
    end
  end

  defp settle_rooms(group, rooms, refundable?, refund_method, occurred_on, operation) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from allocation in RoomFundingAllocation,
          where: allocation.room_id in ^room_ids,
          order_by: [asc: allocation.id]
      )

    cash_allocations = Enum.filter(allocations, &(&1.funding_type == "cash"))
    credit_allocations = Enum.filter(allocations, &(&1.funding_type == "credit"))
    cash = sum(cash_allocations, :amount_cents)

    {refunded, retained, converted, credit_issued} =
      case {refundable?, refund_method} do
        {true, "cash"} ->
          update_payment_dispositions(cash_allocations, group.group_id, :refunded_cents)
          {cash, 0, 0, 0}

        {true, "hotel_credit"} ->
          update_payment_dispositions(
            cash_allocations,
            group.group_id,
            :converted_to_credit_cents
          )

          issued = issue_credit_lot(group, cash_allocations, cash, occurred_on, operation)
          {0, 0, cash, issued}

        {false, "cash"} ->
          update_payment_dispositions(cash_allocations, group.group_id, :retained_cents)
          {0, cash, 0, 0}
      end

    Enum.each(cash_allocations, &Repo.delete!/1)

    credit_effects =
      Enum.reduce(credit_allocations, %{expired: 0, consumed: 0, absorbed: 0}, fn allocation,
                                                                                  effects ->
        lot_effects =
          if refundable?,
            do: restore_credit(allocation, occurred_on),
            else: %{expired: 0, consumed: consume_settled_credit(allocation), absorbed: 0}

        Repo.delete!(allocation)

        %{
          expired: effects.expired + lot_effects.expired,
          consumed: effects.consumed + lot_effects.consumed,
          absorbed: effects.absorbed + lot_effects.absorbed
        }
      end)

    Enum.each(rooms, fn room ->
      room
      |> change(status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0)
      |> Repo.update!()
    end)

    group =
      sync_group_active_totals(group,
        cash_refunded_cents: group.cash_refunded_cents + refunded,
        cash_retained_cents: group.cash_retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
        revision: group.revision + 1
      )

    Finance.record_cash(operation_id(operation), occurred_on, %{
      group.property_id => %{
        refunded_cents: refunded,
        retained_cents: retained,
        converted_to_credit_cents: converted
      }
    })

    Finance.record_credit(operation_id(operation), occurred_on, %{
      issued_cents: credit_issued,
      expired_cents: credit_effects.expired,
      consumed_cents: credit_effects.consumed,
      absorbed_cents: credit_effects.absorbed
    })

    {group,
     %{refunded: refunded, retained: retained, converted: converted, credit_issued: credit_issued}}
  end

  defp issue_credit_lot(_group, _allocations, 0, _occurred_on, _operation), do: 0

  defp issue_credit_lot(group, allocations, cash, occurred_on, operation) do
    issued = credit_with_bonus(cash)

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id(operation),
        remaining_cents: issued,
        issued_on: occurred_on,
        expires_on: Date.add(occurred_on, 365),
        unrecovered_clawback_cents: 0
      })

    allocations |> cash_contributors() |> insert_entitlements(lot)
    Finance.schedule_expiry(lot, issued, occurred_on)
    issued
  end

  defp cash_contributors(allocations) do
    Enum.reduce(allocations, [], fn allocation, contributors ->
      key = allocation.payment_operation_id

      case Enum.find_index(contributors, fn {id, _amount} -> id == key end) do
        nil ->
          contributors ++ [{key, allocation.amount_cents}]

        index ->
          List.update_at(contributors, index, fn {id, amount} ->
            {id, amount + allocation.amount_cents}
          end)
      end
    end)
  end

  defp insert_entitlements(contributors, lot) do
    Enum.reduce(contributors, 0, fn {payment_id, principal}, running ->
      next = running + principal
      entitlement = credit_with_bonus(next) - credit_with_bonus(running)

      Repo.insert!(%CreditEntitlement{
        credit_lot_id: lot.id,
        payment_operation_id: payment_id,
        principal_cents: principal,
        entitlement_cents: entitlement,
        revoked_cents: 0
      })

      next
    end)
  end

  defp update_payment_dispositions(allocations, group_id, disposition) do
    allocations
    |> Enum.reject(&is_nil(&1.payment_operation_id))
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.each(fn {payment_id, rows} ->
      amount = sum(rows, :amount_cents)
      payment = Repo.get!(CashPayment, payment_id)

      payment
      |> change([
        {:held_cents, payment.held_cents - amount},
        {disposition, Map.fetch!(payment, disposition) + amount}
      ])
      |> Repo.update!()

      record_payment_disposition(payment_id, group_id, disposition, amount)
    end)
  end

  defp record_payment_disposition(payment_id, group_id, disposition, amount) do
    disposition_name = disposition_name(disposition)

    case Repo.get_by(CashPaymentDisposition,
           payment_operation_id: payment_id,
           group_id: group_id,
           disposition: disposition_name
         ) do
      nil ->
        Repo.insert!(%CashPaymentDisposition{
          payment_operation_id: payment_id,
          group_id: group_id,
          disposition: disposition_name,
          amount_cents: amount
        })

      row ->
        row |> change(amount_cents: row.amount_cents + amount) |> Repo.update!()
    end
  end

  defp disposition_name(:refunded_cents), do: "refunded"
  defp disposition_name(:retained_cents), do: "retained"
  defp disposition_name(:converted_to_credit_cents), do: "converted_to_credit"

  defp restore_credit(allocation, occurred_on) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    absorbed = min(allocation.amount_cents, lot.unrecovered_clawback_cents)
    excess = allocation.amount_cents - absorbed
    restorable = if Date.compare(lot.expires_on, occurred_on) == :lt, do: 0, else: excess

    lot
    |> change(
      remaining_cents: lot.remaining_cents + restorable,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
    )
    |> Repo.update!()

    room = Repo.get!(Room, allocation.room_id)
    decrement_credit_allocation(allocation.credit_lot_id, room.group_id, allocation.amount_cents)

    Finance.schedule_expiry(lot, restorable, occurred_on)

    %{
      expired: excess - restorable,
      consumed: 0,
      absorbed: absorbed
    }
  end

  defp consume_settled_credit(allocation) do
    room = Repo.get!(Room, allocation.room_id)
    decrement_credit_allocation(allocation.credit_lot_id, room.group_id, allocation.amount_cents)
    allocation.amount_cents
  end

  defp decrement_credit_allocation(lot_id, group_id, amount) do
    allocation =
      Repo.get_by!(CreditAllocation, credit_lot_id: lot_id, group_id: group_id)

    if allocation.amount_cents == amount do
      Repo.delete!(allocation)
    else
      allocation |> change(amount_cents: allocation.amount_cents - amount) |> Repo.update!()
    end
  end

  defp draw_transfer_chunks(source_group_id, amount) do
    allocations =
      Repo.all(
        from allocation in RoomFundingAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.group_id == ^source_group_id and room.status == "active",
          order_by: [desc: allocation.id],
          select: allocation
      )

    {chunks, remaining} =
      Enum.reduce_while(allocations, {[], amount}, fn allocation, {chunks, remaining} ->
        room = Repo.get!(Room, allocation.room_id)
        moved = min(allocation.amount_cents, remaining)
        field = funding_room_field(allocation.funding_type)

        room
        |> change([{field, Map.fetch!(room, field) - moved}])
        |> Repo.update!()

        if allocation.funding_type == "credit" do
          decrement_credit_allocation(allocation.credit_lot_id, source_group_id, moved)
        else
          mark_payment_transferred(allocation.payment_operation_id)
        end

        if moved == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          allocation |> change(amount_cents: allocation.amount_cents - moved) |> Repo.update!()
        end

        chunk = %{
          amount: moved,
          funding_type: allocation.funding_type,
          payment_id: allocation.payment_operation_id,
          funding_operation_id: allocation.funding_operation_id,
          lot_id: allocation.credit_lot_id
        }

        state = {[chunk | chunks], remaining - moved}
        if moved == remaining, do: {:halt, state}, else: {:cont, state}
      end)

    if remaining != 0, do: raise("transfer allocation invariant violated")
    Enum.reverse(chunks)
  end

  defp allocate_transfer_chunk(destination_group_id, chunk) do
    if chunk.funding_type == "credit" do
      upsert_credit_allocation(chunk.lot_id, destination_group_id, chunk.amount)
    end

    allocate_chunks(active_rooms(destination_group_id), [chunk], chunk.funding_type)
  end

  defp funding_room_field("cash"), do: :cash_paid_cents
  defp funding_room_field("credit"), do: :credit_paid_cents

  defp mark_payment_transferred(nil), do: :ok

  defp mark_payment_transferred(payment_operation_id) do
    case Repo.get(CashPayment, payment_operation_id) do
      %CashPayment{participated_in_transfer: false} = payment ->
        payment |> change(participated_in_transfer: true) |> Repo.update!()

      _payment ->
        :ok
    end
  end

  defp remove_held_cash(_payment_id, 0), do: %{}

  defp remove_held_cash(payment_id, amount) do
    allocations =
      Repo.all(
        from allocation in RoomFundingAllocation,
          where:
            allocation.payment_operation_id == ^payment_id and allocation.funding_type == "cash",
          order_by: [desc: allocation.id]
      )

    {remaining, removed_by_group} =
      Enum.reduce_while(allocations, {amount, %{}}, fn allocation,
                                                       {remaining, removed_by_group} ->
        removed = min(allocation.amount_cents, remaining)
        room = Repo.get!(Room, allocation.room_id)
        room |> change(cash_paid_cents: room.cash_paid_cents - removed) |> Repo.update!()

        if removed == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          allocation |> change(amount_cents: allocation.amount_cents - removed) |> Repo.update!()
        end

        state = {
          remaining - removed,
          Map.update(removed_by_group, room.group_id, removed, &(&1 + removed))
        }

        if removed == remaining, do: {:halt, state}, else: {:cont, state}
      end)

    if remaining != 0, do: raise("held cash allocation invariant violated")
    removed_by_group
  end

  defp revoke_payment_entitlements(payment_id, occurred_on) do
    Repo.all(
      from entitlement in CreditEntitlement,
        where:
          entitlement.payment_operation_id == ^payment_id and
            entitlement.revoked_cents < entitlement.entitlement_cents,
        order_by: [asc: entitlement.id]
    )
    |> Enum.reduce(0, fn entitlement, revoked ->
      amount = entitlement.entitlement_cents - entitlement.revoked_cents
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      from_available = min(amount, lot.remaining_cents)

      liability_revoked =
        if Date.compare(occurred_on, lot.expires_on) == :gt, do: 0, else: from_available

      Finance.unschedule_expiry(lot, liability_revoked, occurred_on)

      lot
      |> change(
        remaining_cents: lot.remaining_cents - from_available,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + amount - from_available
      )
      |> Repo.update!()

      entitlement |> change(revoked_cents: entitlement.entitlement_cents) |> Repo.update!()
      revoked + liability_revoked
    end)
  end

  defp allocate_cash(group_id, amount, payment_id, funding_operation_id) do
    chunks = [
      %{amount: amount, payment_id: payment_id, funding_operation_id: funding_operation_id}
    ]

    allocate_chunks(active_rooms(group_id), chunks, "cash")
  end

  defp allocate_credit(group_id, chunks, funding_operation_id) do
    chunks = Enum.map(chunks, &Map.put(&1, :funding_operation_id, funding_operation_id))
    allocate_chunks(active_rooms(group_id), chunks, "credit")
  end

  defp allocate_chunks(rooms, chunks, type) do
    chunks =
      Enum.reduce(rooms, chunks, fn room, pending ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        {used, pending} = allocate_room_chunks(room, pending, capacity, type)

        if used > 0 do
          field = if type == "cash", do: :cash_paid_cents, else: :credit_paid_cents
          room |> change([{field, Map.fetch!(room, field) + used}]) |> Repo.update!()
        end

        pending
      end)

    if Enum.any?(chunks, &(&1.amount > 0)), do: raise("funding allocation invariant violated")
    :ok
  end

  defp allocate_room_chunks(_room, chunks, 0, _type), do: {0, chunks}
  defp allocate_room_chunks(_room, [], _capacity, _type), do: {0, []}

  defp allocate_room_chunks(room, [chunk | rest], capacity, type) do
    used = min(chunk.amount, capacity)

    if used > 0 do
      Repo.insert!(%RoomFundingAllocation{
        room_id: room.id,
        funding_type: type,
        payment_operation_id: Map.get(chunk, :payment_id),
        funding_operation_id: Map.get(chunk, :funding_operation_id),
        credit_lot_id: Map.get(chunk, :lot_id),
        amount_cents: used
      })
    end

    next_chunks =
      if used == chunk.amount,
        do: rest,
        else: [%{chunk | amount: chunk.amount - used} | rest]

    if used == capacity do
      {used, next_chunks}
    else
      {more, final_chunks} = allocate_room_chunks(room, next_chunks, capacity - used, type)
      {used + more, final_chunks}
    end
  end

  defp consume_credit_lots(lots, group_id, amount, occurred_on) do
    {chunks, remaining} =
      Enum.reduce_while(lots, {[], amount}, fn lot, {chunks, remaining} ->
        used = min(lot.remaining_cents, remaining)
        Finance.unschedule_expiry(lot, used, occurred_on)
        lot |> change(remaining_cents: lot.remaining_cents - used) |> Repo.update!()
        upsert_credit_allocation(lot.id, group_id, used)
        state = {chunks ++ [%{lot_id: lot.id, amount: used}], remaining - used}
        if used == remaining, do: {:halt, state}, else: {:cont, state}
      end)

    if remaining != 0, do: raise("credit consumption invariant violated")
    chunks
  end

  defp upsert_credit_allocation(lot_id, group_id, amount) do
    case Repo.get_by(CreditAllocation, credit_lot_id: lot_id, group_id: group_id) do
      nil ->
        Repo.insert!(%CreditAllocation{
          credit_lot_id: lot_id,
          group_id: group_id,
          amount_cents: amount
        })

      allocation ->
        allocation |> change(amount_cents: allocation.amount_cents + amount) |> Repo.update!()
    end
  end

  defp update_group_funding(group, cash, credit) do
    group
    |> change(
      deposit_paid_cents: group.deposit_paid_cents + cash + credit,
      cash_paid_cents: group.cash_paid_cents + cash,
      credit_paid_cents: group.credit_paid_cents + credit,
      revision: group.revision + 1
    )
    |> Repo.update!()
  end

  defp sync_group_active_totals(group, extra_changes) do
    rooms = active_rooms(group.group_id)
    lodging = sum(rooms, :lodging_total_cents)
    due = sum(rooms, :deposit_due_cents)
    cash = sum(rooms, :cash_paid_cents)
    credit = sum(rooms, :credit_paid_cents)

    base = [
      status: if(rooms == [], do: "cancelled", else: "active"),
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      deposit_paid_cents: cash + credit,
      cash_paid_cents: cash,
      credit_paid_cents: credit
    ]

    group |> change(Keyword.merge(base, extra_changes)) |> Repo.update!()
  end

  defp ensure_payment_entitlements(%CashPayment{converted_to_credit_cents: 0}), do: :ok

  defp ensure_payment_entitlements(payment) do
    count =
      Repo.aggregate(
        from(entitlement in CreditEntitlement,
          where: entitlement.payment_operation_id == ^payment.payment_operation_id
        ),
        :count
      )

    if count == 0 do
      operation_ids =
        Repo.all(
          from operation in PartnerOperation,
            where: operation.operation_type in ["cancel_group", "cancel_rooms"],
            order_by: [asc: operation.commit_order]
        )
        |> Enum.filter(fn operation ->
          operation.result["status"] == "applied" and
            operation.result["group_id"] == payment.original_group_id
        end)
        |> Enum.map(& &1.operation_id)

      Repo.all(from lot in CreditLot, where: lot.source_operation_id in ^operation_ids)
      |> Enum.each(&backfill_lot_entitlements(&1, payment.original_group_id))
    end

    :ok
  end

  defp backfill_lot_entitlements(lot, group_id) do
    count =
      Repo.aggregate(from(e in CreditEntitlement, where: e.credit_lot_id == ^lot.id), :count)

    if count == 0 do
      payments =
        Repo.all(
          from payment in CashPayment,
            join: operation in PartnerOperation,
            on: operation.operation_id == payment.payment_operation_id,
            where:
              payment.original_group_id == ^group_id and payment.converted_to_credit_cents > 0,
            order_by: [asc: operation.commit_order]
        )

      source = Repo.get_by(PartnerOperation, operation_id: lot.source_operation_id)
      issued = if source, do: source.result["credit_issued_cents"] || 0, else: 0
      payment_principal = Enum.sum(Enum.map(payments, & &1.converted_to_credit_cents))
      legacy = max(principal_from_issued(issued) - payment_principal, 0)

      ([{nil, legacy}] ++
         Enum.map(payments, &{&1.payment_operation_id, &1.converted_to_credit_cents}))
      |> Enum.reject(fn {_id, amount} -> amount == 0 end)
      |> insert_entitlements(lot)
    end
  end

  defp principal_from_issued(issued) do
    Stream.iterate(max(div(issued * 10, 11) - 2, 0), &(&1 + 1))
    |> Enum.find(fn principal -> credit_with_bonus(principal) == issued end)
  end

  defp target_payment(operation, error_code) do
    payment_operation_id = operation["payment_operation_id"]

    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, "operation_not_found"}

      _operation ->
        case Repo.get(CashPayment, payment_operation_id) do
          nil ->
            {:error, error_code}

          payment ->
            {:ok, payment}
        end
    end
  end

  defp payment_dispositions_by_group(payment_operation_id) do
    Repo.all(
      from disposition in CashPaymentDisposition,
        where: disposition.payment_operation_id == ^payment_operation_id
    )
    |> Enum.reduce(%{}, fn disposition, groups ->
      field =
        case disposition.disposition do
          "refunded" -> :refunded_cents
          "retained" -> :retained_cents
          "converted_to_credit" -> :converted_to_credit_cents
        end

      Map.update(
        groups,
        disposition.group_id,
        %{refunded_cents: 0, retained_cents: 0, converted_to_credit_cents: 0}
        |> Map.put(field, disposition.amount_cents),
        &Map.update!(&1, field, fn amount -> amount + disposition.amount_cents end)
      )
    end)
  end

  defp payment_data(payment) do
    data = %{
      payment_operation_id: payment.payment_operation_id,
      original_group_id: payment.original_group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: payment.held_cents,
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_to_credit_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }

    if payment.participated_in_transfer do
      Map.put(data, :held_by_group, held_cash_by_group(payment.payment_operation_id))
    else
      data
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in RoomFundingAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where:
          allocation.funding_type == "cash" and
            allocation.payment_operation_id == ^payment_operation_id and room.status == "active",
        group_by: room.group_id,
        order_by: room.group_id,
        select: %{group_id: room.group_id, amount_cents: sum(allocation.amount_cents)}
    )
  end

  defp room_data(room) do
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

  defp load_group(group_id) do
    Repo.get!(Group, group_id)
    |> Repo.preload(rooms: from(room in Room, order_by: room.position))
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: room.position
    )
  end

  defp selected_active_rooms(group_id, room_ids) when is_list(room_ids) and room_ids != [] do
    valid_ids? = Enum.all?(room_ids, &(is_binary(&1) and &1 != ""))

    rooms =
      Repo.all(
        from room in Room,
          where:
            room.group_id == ^group_id and room.status == "active" and room.room_id in ^room_ids,
          order_by: room.position
      )

    if valid_ids? and length(Enum.uniq(room_ids)) == length(room_ids) and
         length(rooms) == length(room_ids),
       do: {:ok, rooms},
       else: {:error, "invalid_rooms"}
  end

  defp selected_active_rooms(_group_id, _room_ids), do: {:error, "invalid_rooms"}

  defp active_credit_by_lot do
    Repo.all(
      from allocation in RoomFundingAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.funding_type == "credit" and room.status == "active",
        group_by: allocation.credit_lot_id,
        select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
    )
    |> Map.new()
  end

  defp cash_movements_for_groups(amounts_by_group, field) do
    Enum.reduce(amounts_by_group, %{}, fn {group_id, amount}, movements ->
      property_id = Repo.get!(Group, group_id).property_id
      add_cash_movement(movements, property_id, field, amount)
    end)
  end

  defp add_settlement_reversals(movements, settled_by_group) do
    Enum.reduce(settled_by_group, movements, fn {group_id, dispositions}, movements ->
      property_id = Repo.get!(Group, group_id).property_id

      movements
      |> add_cash_movement(property_id, :refunded_cents, -dispositions.refunded_cents)
      |> add_cash_movement(property_id, :retained_cents, -dispositions.retained_cents)
      |> add_cash_movement(
        property_id,
        :converted_to_credit_cents,
        -dispositions.converted_to_credit_cents
      )
      |> add_cash_movement(
        property_id,
        :charged_back_cents,
        dispositions.refunded_cents + dispositions.retained_cents +
          dispositions.converted_to_credit_cents
      )
    end)
  end

  defp add_cash_movement(movements, _property_id, _field, 0), do: movements

  defp add_cash_movement(movements, property_id, field, amount) do
    Map.update(
      movements,
      property_id,
      %{field => amount},
      &Map.update(&1, field, amount, fn current -> current + amount end)
    )
  end

  defp empty_cash_totals do
    %{
      cash_held_cents: 0,
      cash_refunded_cents: 0,
      cash_retained_cents: 0,
      cash_converted_to_credit_cents: 0,
      cash_reduced_cents: 0,
      cash_charged_back_cents: 0
    }
  end

  defp structurally_complete?(type, operation) do
    required =
      case type do
        "open_group" ->
          ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

        type when type in ~w(record_cash_payment apply_hotel_credit) ->
          ~w(operation_id type occurred_on group_id amount_cents)

        "reschedule_group" ->
          ~w(operation_id type occurred_on group_id new_arrival_on)

        "cancel_group" ->
          ~w(operation_id type occurred_on group_id)

        "cancel_rooms" ->
          ~w(operation_id type occurred_on group_id room_ids)

        "reduce_cash_payment" ->
          ~w(operation_id type occurred_on payment_operation_id amount_cents)

        "charge_back_payment" ->
          ~w(operation_id type occurred_on payment_operation_id)

        "transfer_deposit" ->
          ~w(operation_id type occurred_on source_group_id destination_group_id amount_cents)

        "start_finance_reporting" ->
          ~w(operation_id type)
      end

    Enum.all?(required, &Map.has_key?(operation, &1)) and is_binary(operation["operation_id"])
  end

  defp validate_identifiers(operation, fields) do
    if Enum.all?(fields, fn field -> is_binary(operation[field]) and operation[field] != "" end),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn room ->
        is_map(room) and is_binary(room["room_id"]) and room["room_id"] != "" and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] > 0
      end)

    ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid? and length(Enum.uniq(ids)) == length(ids) do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}
  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_amount), do: {:error, "invalid_amount"}

  defp validate_refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ~w(cash hotel_credit) -> {:ok, method}
      _method -> {:error, "invalid_operation"}
    end
  end

  defp ensure_refund_method_available("hotel_credit", false),
    do: {:error, "refund_method_not_available"}

  defp ensure_refund_method_available(_method, _refundable?), do: :ok

  defp parse_date(value, error_code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, error_code}
    end
  end

  defp parse_date(_value, error_code), do: {:error, error_code}
  defp read_date(nil), do: {:ok, Date.utc_today()}

  defp read_date(value) do
    case parse_date(value, :invalid_date) do
      {:ok, date} -> {:ok, date}
      {:error, :invalid_date} -> {:error, :invalid_date}
    end
  end

  defp ensure_group_absent(group_id) do
    if Repo.get(Group, group_id),
      do: {:error, "group_already_exists"},
      else: :ok
  end

  defp fetch_group(operation) do
    case Repo.get(Group, operation["group_id"]) do
      nil ->
        domain_error(operation, "group_not_found")

      group ->
        {:ok, group}
    end
  end

  defp fetch_group_by_id(operation, group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        {:error,
         rejected(operation_id(operation), "group_not_found")
         |> Map.put(:group_id, group_id)}

      group ->
        {:ok, group}
    end
  end

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error,
       rejected(operation_id(operation), "stale_revision")
       |> Map.merge(%{
         group_id: group.group_id,
         expected_revision: operation["expected_revision"],
         actual_revision: group.revision
       })}
    else
      :ok
    end
  end

  defp check_destination_revision(group, operation) do
    if Map.has_key?(operation, "destination_expected_revision") and
         operation["destination_expected_revision"] != group.revision do
      {:error,
       rejected(operation_id(operation), "stale_revision")
       |> Map.merge(%{
         group_id: group.group_id,
         expected_revision: operation["destination_expected_revision"],
         actual_revision: group.revision
       })}
    else
      :ok
    end
  end

  defp validate_transfer_groups(source, destination) do
    if source.group_id != destination.group_id and source.guest_id == destination.guest_id,
      do: :ok,
      else: {:error, "invalid_transfer"}
  end

  defp ensure_transfer_active(%Group{status: "active"}, _operation), do: :ok

  defp ensure_transfer_active(group, operation) do
    {:error,
     rejected(operation_id(operation), "group_not_active")
     |> Map.put(:group_id, group.group_id)}
  end

  defp ensure_transfer_funding(group, amount) do
    if amount <= group.cash_paid_cents + group.credit_paid_cents,
      do: :ok,
      else: {:error, "transfer_exceeds_held_funding"}
  end

  defp ensure_transfer_capacity(group, amount) do
    if amount <= outstanding_deposit(group),
      do: :ok,
      else: {:error, "transfer_exceeds_outstanding"}
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, "group_not_active"}
  defp ensure_payment_held(%CashPayment{held_cents: held}, _code) when held > 0, do: :ok
  defp ensure_payment_held(_payment, code), do: {:error, code}

  defp ensure_reduction_within_held(payment, amount) do
    if amount <= payment.held_cents,
      do: :ok,
      else: {:error, "reduction_exceeds_held_cash"}
  end

  defp ensure_chargeable(%CashPayment{charged_back_cents: amount}) when amount > 0,
    do: {:error, "payment_not_chargeable"}

  defp ensure_chargeable(%CashPayment{recorded_cents: recorded, reduced_cents: recorded}),
    do: {:error, "payment_not_chargeable"}

  defp ensure_chargeable(_payment), do: :ok

  defp ensure_not_overpaid(group, amount) do
    if amount <= outstanding_deposit(group),
      do: :ok,
      else: {:error, "payment_exceeds_outstanding"}
  end

  defp outstanding_deposit(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging
  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @new_flexible_policy_on) == :lt,
      do: "flex-14",
      else: "flex-30"
  end

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until("advance-nonrefundable", _arrival_on), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group.policy_version, group.arrival_on) do
      nil -> false
      date -> Date.compare(occurred_on, date) != :gt
    end
  end

  defp credit_lots_for_application(guest_id, amount, occurred_on) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
              lot.issued_on <= ^occurred_on and lot.expires_on >= ^occurred_on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    if sum(lots, :remaining_cents) >= amount,
      do: {:ok, lots},
      else: {:error, "insufficient_credit"}
  end

  defp credit_with_bonus(cash), do: cash + div(cash * 10 + 50, 100)
  defp sum(enumerable, field), do: Enum.sum(Enum.map(enumerable, &Map.fetch!(&1, field)))
  defp iso_date(nil), do: nil
  defp iso_date(date), do: Date.to_iso8601(date)

  defp applied(operation, fields) do
    {:ok, Map.merge(fields, %{operation_id: operation_id(operation), status: "applied"})}
  end

  defp domain_error(operation, code), do: {:error, rejected(operation_id(operation), code)}

  defp rejected(operation_id, code),
    do: %{operation_id: operation_id, status: "rejected", code: code}

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil
  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_operation), do: nil
  defp json_data(data), do: data |> Jason.encode!() |> Jason.decode!()
end
