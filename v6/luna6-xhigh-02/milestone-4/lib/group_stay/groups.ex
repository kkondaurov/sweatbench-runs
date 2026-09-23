defmodule GroupStay.Groups do
  @moduledoc "Operations and read models for group reservations."

  import Ecto.Query

  alias GroupStay.Groups.{Group, OperationRecord, Room}

  alias GroupStay.Ledger.{
    CashPayment,
    CreditAllocation,
    CreditLot,
    CreditLotEntitlement,
    Entry,
    RoomCashAllocation
  }

  alias GroupStay.Repo

  @max_integer 9_223_372_036_854_775_807

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        rooms =
          Repo.all(
            from room in Room,
              where: room.group_id == ^group_id,
              order_by: [asc: room.position, asc: room.id]
          )

        {group, rooms}
    end
  end

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def get_payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get(CashPayment, payment_operation_id) do
      nil ->
        case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
          nil -> :not_found
          _record -> :not_reconcilable
        end

      payment ->
        %{
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
    end
  end

  def ledger_totals(on \\ Date.utc_today()) do
    totals =
      Repo.all(
        from entry in Entry,
          select: {entry.kind, entry.amount_cents}
      )
      |> Enum.reduce(%{}, fn {kind, amount}, totals ->
        Map.update(totals, kind, amount, &(&1 + amount))
      end)

    received = Map.get(totals, "payment", 0) || 0
    refunded = (Map.get(totals, "refund", 0) || 0) - (Map.get(totals, "refund_reversal", 0) || 0)

    retained =
      (Map.get(totals, "retention", 0) || 0) - (Map.get(totals, "retention_reversal", 0) || 0)

    converted =
      (Map.get(totals, "cash_to_credit", 0) || 0) -
        (Map.get(totals, "cash_to_credit_reversal", 0) || 0)

    reduced = Map.get(totals, "cash_reduced", 0) || 0
    charged_back = Map.get(totals, "cash_charged_back", 0) || 0

    available_credit = available_credit_total(on)

    applied_credit =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: allocation.group_id == group.group_id,
          join: lot in CreditLot,
          on: allocation.credit_lot_id == lot.id,
          where: group.status == "active",
          where: lot.issued_on <= ^on,
          select: sum(allocation.amount_cents)
      ) || 0

    shortfall = credit_shortfall_total()

    %{
      cash_held_cents: received - refunded - retained - converted - reduced - charged_back,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      cash_reduced_cents: reduced,
      cash_charged_back_cents: charged_back,
      credit_liability_cents: available_credit + applied_credit,
      credit_shortfall_cents: shortfall
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  def cancellation_policy(%Group{} = group) do
    %{
      policy_version: group.policy_version,
      refundable_until: refundable_until(group.policy_version, group.arrival_on)
    }
  end

  defp apply_operation(operation) when not is_map(operation) do
    rejected(nil, "invalid_operation")
  end

  defp apply_operation(operation) do
    operation_id = Map.get(operation, "operation_id")

    # Serialize the idempotency check and its domain effects against concurrent retries.
    {:ok, result} =
      Repo.transaction(fn -> process_idempotent_operation(operation, operation_id) end,
        mode: :immediate
      )

    result
  end

  defp process_idempotent_operation(operation, operation_id) do
    if valid_identifier?(operation_id) do
      case Repo.get_by(OperationRecord, operation_id: operation_id) do
        nil ->
          result = operation |> run_domain_operation() |> json_value()

          Repo.insert!(
            OperationRecord.changeset(%OperationRecord{}, %{
              operation_id: operation_id,
              operation_type: operation_type(operation),
              submission: operation,
              result: result
            })
          )

          result

        %OperationRecord{submission: ^operation, result: result} ->
          result

        %OperationRecord{} ->
          rejected(operation_id, "operation_id_conflict") |> json_value()
      end
    else
      operation |> run_domain_operation() |> json_value()
    end
  end

  defp run_domain_operation(operation) do
    Repo.query!("SAVEPOINT group_stay_operation")

    # A handled rejection rolls back only domain work so its result can still be recorded.
    result =
      try do
        apply_domain_operation(operation)
      catch
        {:handled_rejection, result} ->
          Repo.query!("ROLLBACK TO SAVEPOINT group_stay_operation")
          result
      end

    Repo.query!("RELEASE SAVEPOINT group_stay_operation")
    result
  end

  defp apply_domain_operation(operation) do
    operation_id = Map.get(operation, "operation_id")

    result =
      case Map.get(operation, "type") do
        "open_group" -> apply_open_group(operation)
        "record_cash_payment" -> apply_existing_group_operation(operation, :payment)
        "apply_hotel_credit" -> apply_existing_group_operation(operation, :credit)
        "reschedule_group" -> apply_existing_group_operation(operation, :reschedule)
        "cancel_group" -> apply_existing_group_operation(operation, :cancel)
        "cancel_rooms" -> apply_existing_group_operation(operation, :cancel_rooms)
        "reduce_cash_payment" -> apply_cash_adjustment(operation, :reduce)
        "charge_back_payment" -> apply_cash_adjustment(operation, :charge_back)
        _ -> rejected(operation_id, "invalid_operation")
      end

    if Map.get(result, :status) == "rejected" do
      result
    else
      Map.merge(result, %{status: "applied", operation_id: operation_id})
    end
  end

  defp apply_open_group(operation) do
    operation_id = Map.get(operation, "operation_id")
    group_id = Map.get(operation, "group_id")

    if not valid_identifier?(operation_id) or not valid_identifier?(group_id) do
      rejected(operation_id, "invalid_operation")
    else
      if Repo.get(Group, group_id) do
        reject!(
          {:rejected, rejected(operation_id, "group_already_exists", %{group_id: group_id})}
        )
      end

      required = [
        "occurred_on",
        "guest_id",
        "property_id",
        "arrival_on",
        "departure_on",
        "rate_plan",
        "rooms"
      ]

      if Enum.any?(required, &(not Map.has_key?(operation, &1))) do
        reject!({:rejected, rejected(operation_id, "invalid_operation")})
      end

      unless valid_identifier?(operation["guest_id"]) and
               valid_identifier?(operation["property_id"]) do
        reject!({:rejected, rejected(operation_id, "invalid_operation")})
      end

      with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
           {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
           {:ok, departure_on} <- parse_date(operation["departure_on"]),
           true <- Date.compare(departure_on, arrival_on) == :gt,
           {:ok, rate_plan} <- parse_rate_plan(operation["rate_plan"]),
           {:ok, rooms, lodging_total, deposit_due} <-
             calculate_rooms(operation["rooms"], arrival_on, departure_on, rate_plan) do
        attrs = %{
          group_id: group_id,
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          policy_version: policy_version(rate_plan, booked_on),
          status: "active",
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          revision: 1
        }

        group =
          case Repo.insert(Group.changeset(%Group{}, attrs)) do
            {:ok, group} ->
              group

            {:error, changeset} ->
              if Keyword.has_key?(changeset.errors, :group_id) do
                reject!(
                  {:rejected,
                   rejected(operation_id, "group_already_exists", %{group_id: group_id})}
                )
              else
                reject!({:rejected, rejected(operation_id, "invalid_operation")})
              end
          end

        rooms
        |> Enum.with_index()
        |> Enum.each(fn {room, position} ->
          Repo.insert!(
            Room.changeset(%Room{}, %{
              group_id: group_id,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: position,
              lodging_total_cents: room.lodging,
              deposit_due_cents: room.deposit_due,
              deposit_paid_cents: 0,
              cash_paid_cents: 0,
              credit_paid_cents: 0,
              status: "active"
            })
          )
        end)

        %{
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        }
      else
        false ->
          reject!({:rejected, rejected(operation_id, "invalid_stay")})

        {:error, :invalid_rate_plan} ->
          reject!({:rejected, rejected(operation_id, "invalid_rate_plan")})

        {:error, :invalid_rooms} ->
          reject!({:rejected, rejected(operation_id, "invalid_rooms")})

        _ ->
          reject!({:rejected, rejected(operation_id, "invalid_stay")})
      end
    end
  end

  defp apply_existing_group_operation(operation, kind) do
    operation_id = Map.get(operation, "operation_id")
    group_id = Map.get(operation, "group_id")

    if not valid_identifier?(group_id) do
      rejected(operation_id, "invalid_operation")
    else
      case Repo.get(Group, group_id) do
        nil ->
          reject!({:rejected, rejected(operation_id, "group_not_found", %{group_id: group_id})})

        group ->
          if Map.has_key?(operation, "expected_revision") and
               operation["expected_revision"] !== group.revision do
            reject!(
              {:rejected,
               rejected(operation_id, "stale_revision", %{
                 group_id: group_id,
                 expected_revision: operation["expected_revision"],
                 actual_revision: group.revision
               })}
            )
          end

          apply_to_existing_group(group, operation, kind)
      end
    end
  end

  defp apply_to_existing_group(group, operation, kind) do
    operation_id = Map.get(operation, "operation_id")

    required = ["operation_id", "occurred_on"]

    if Enum.any?(required, &(not Map.has_key?(operation, &1))) or
         not valid_identifier?(operation_id) do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    case parse_date(operation["occurred_on"]) do
      {:ok, occurred_on} ->
        apply_validated_group_operation(group, operation, kind, occurred_on)

      :error ->
        reject!(
          {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
        )
    end
  end

  defp apply_validated_group_operation(group, operation, :payment, occurred_on) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      reject!(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    if not Map.has_key?(operation, "amount_cents") do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    amount = operation["amount_cents"]

    if not (is_integer(amount) and amount > 0) do
      reject!({:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})})
    end

    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    if amount > outstanding do
      reject!(
        {:rejected,
         rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})}
      )
    end

    revision = group.revision + 1

    Repo.insert!(
      Entry.changeset(%Entry{}, %{
        group_id: group.group_id,
        kind: "payment",
        amount_cents: amount,
        occurred_on: occurred_on,
        operation_id: operation_id
      })
    )

    Repo.insert!(
      CashPayment.changeset(%CashPayment{}, %{
        payment_operation_id: operation_id,
        group_id: group.group_id,
        recorded_cents: amount,
        held_cents: amount
      })
    )

    allocate_funding_to_rooms(group, amount, :cash, operation_id)
    update_group_totals(group, revision)

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding - amount,
      revision: revision
    }
  end

  defp apply_validated_group_operation(group, operation, :credit, occurred_on) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      reject!(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    if not Map.has_key?(operation, "amount_cents") do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    amount = operation["amount_cents"]

    if not (is_integer(amount) and amount > 0) do
      reject!({:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})})
    end

    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    if amount > outstanding do
      reject!(
        {:rejected,
         rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})}
      )
    end

    lots = available_credit_lots(group.guest_id, occurred_on)
    available = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    if available < amount do
      reject!(
        {:rejected, rejected(operation_id, "insufficient_credit", %{group_id: group.group_id})}
      )
    end

    revision = group.revision + 1

    allocate_credit_to_rooms(group, lots, amount, operation_id)
    update_group_totals(group, revision)

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding - amount,
      revision: revision
    }
  end

  defp apply_validated_group_operation(group, operation, :reschedule, occurred_on) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      reject!(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    if not Map.has_key?(operation, "new_arrival_on") do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    with {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      shift = Date.diff(new_arrival, group.arrival_on)

      new_departure =
        try do
          Date.add(group.departure_on, shift)
        rescue
          ArgumentError ->
            reject!(
              {:rejected, rejected(operation_id, "invalid_stay", %{group_id: group.group_id})}
            )
        end

      revision = group.revision + 1

      {:ok, _group} =
        Repo.update(
          Ecto.Changeset.change(group,
            arrival_on: new_arrival,
            departure_on: new_departure,
            revision: revision
          )
        )

      %{
        group_id: group.group_id,
        new_arrival_on: new_arrival,
        new_departure_on: new_departure,
        policy_version: group.policy_version,
        refundable_until: refundable_until(group.policy_version, new_arrival),
        revision: revision
      }
    else
      _ ->
        reject!({:rejected, rejected(operation_id, "invalid_stay", %{group_id: group.group_id})})
    end
  end

  defp apply_validated_group_operation(group, operation, :cancel, occurred_on) do
    selected_room_ids = active_rooms(group.group_id) |> Enum.map(& &1.room_id)
    settle_selected_rooms(group, operation, occurred_on, selected_room_ids, false)
  end

  defp apply_validated_group_operation(group, operation, :cancel_rooms, occurred_on) do
    supplied = Map.get(operation, "room_ids")

    unless is_list(supplied) and supplied != [] and Enum.all?(supplied, &valid_identifier?/1) do
      reject!(
        {:rejected,
         rejected(operation["operation_id"], "invalid_rooms", %{group_id: group.group_id})}
      )
    end

    active_ids = active_rooms(group.group_id) |> Enum.map(& &1.room_id)

    if length(Enum.uniq(supplied)) != length(supplied) or
         Enum.any?(supplied, &(&1 not in active_ids)) do
      reject!(
        {:rejected,
         rejected(operation["operation_id"], "invalid_rooms", %{group_id: group.group_id})}
      )
    end

    settle_selected_rooms(group, operation, occurred_on, supplied, true)
  end

  defp settle_selected_rooms(group, operation, occurred_on, room_ids, return_room_ids?) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      reject!(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    refund_method = Map.get(operation, "refund_method", "cash")

    if refund_method not in ["cash", "hotel_credit"] do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    refundable? =
      case refundable_until(group.policy_version, group.arrival_on) do
        nil -> false
        date -> Date.compare(occurred_on, date) != :gt
      end

    if not refundable? and refund_method == "hotel_credit" do
      reject!(
        {:rejected,
         rejected(operation_id, "refund_method_not_available", %{group_id: group.group_id})}
      )
    end

    selected_rooms = Enum.filter(active_rooms(group.group_id), &(&1.room_id in room_ids))
    selected_ids = Enum.map(selected_rooms, & &1.room_id)

    cash_allocations =
      Repo.all(
        from allocation in RoomCashAllocation,
          where: allocation.group_id == ^group.group_id and allocation.room_id in ^selected_ids,
          order_by: [asc: allocation.id]
      )

    cash_paid = Enum.reduce(cash_allocations, 0, &(&1.amount_cents + &2))

    cash_sources =
      Enum.reduce(cash_allocations, %{}, fn allocation, acc ->
        Map.update(
          acc,
          allocation.payment_operation_id,
          allocation.amount_cents,
          &(&1 + allocation.amount_cents)
        )
      end)

    refunded = if refundable? and refund_method == "cash", do: cash_paid, else: 0
    retained = if refundable?, do: 0, else: cash_paid
    converted = if refundable? and refund_method == "hotel_credit", do: cash_paid, else: 0
    credit_issued = if converted > 0, do: credit_with_bonus(converted), else: 0

    if credit_issued > @max_integer do
      reject!({:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})})
    end

    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.group_id and allocation.room_id in ^selected_ids,
          order_by: [asc: allocation.id]
      )

    Enum.each(cash_allocations, &Repo.delete!/1)

    Enum.each(cash_sources, fn
      {nil, _amount} ->
        :ok

      {payment_id, amount} ->
        update_cash_payment!(payment_id, %{
          held_cents: {:decrement, amount},
          refunded_cents: {:increment, refunded_amount(refunded, cash_sources, payment_id)},
          retained_cents: {:increment, retained_amount(retained, cash_sources, payment_id)},
          converted_to_credit_cents:
            {:increment, converted_amount(converted, cash_sources, payment_id)}
        })
    end)

    Enum.each(allocations, fn allocation ->
      if refundable? do
        restore_credit_allocation(allocation.credit_lot_id, allocation.amount_cents, occurred_on)
      end

      Repo.delete!(allocation)
    end)

    Repo.update_all(
      from(room in Room,
        where: room.group_id == ^group.group_id and room.room_id in ^selected_ids
      ),
      set: [status: "cancelled", deposit_paid_cents: 0, cash_paid_cents: 0, credit_paid_cents: 0]
    )

    if credit_issued > 0 do
      lot =
        Repo.insert!(
          CreditLot.changeset(%CreditLot{}, %{
            guest_id: group.guest_id,
            source_operation_id: operation_id,
            issued_on: occurred_on,
            expires_on: Date.add(occurred_on, 365),
            remaining_cents: credit_issued,
            unrecovered_clawback_cents: 0
          })
        )

      insert_credit_entitlements(lot, cash_sources)
    end

    if refunded > 0, do: insert_entry(group, "refund", refunded, occurred_on, operation_id)
    if retained > 0, do: insert_entry(group, "retention", retained, occurred_on, operation_id)

    if converted > 0,
      do: insert_entry(group, "cash_to_credit", converted, occurred_on, operation_id)

    revision = group.revision + 1
    _updated_group = update_group_totals(group, revision)

    base = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: revision
    }

    if return_room_ids?, do: Map.put(base, :cancelled_room_ids, selected_ids), else: base
  end

  defp refunded_amount(0, _sources, _payment_id), do: 0

  defp refunded_amount(total, sources, payment_id),
    do: min(Map.get(sources, payment_id, 0), total)

  defp retained_amount(0, _sources, _payment_id), do: 0

  defp retained_amount(total, sources, payment_id),
    do: min(Map.get(sources, payment_id, 0), total)

  defp converted_amount(0, _sources, _payment_id), do: 0

  defp converted_amount(total, sources, payment_id),
    do: min(Map.get(sources, payment_id, 0), total)

  defp restore_credit_allocation(lot_id, amount, occurred_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed = min(amount, lot.unrecovered_clawback_cents || 0)
    remaining_clawback = (lot.unrecovered_clawback_cents || 0) - absorbed
    available = amount - absorbed
    add_available = if Date.compare(lot.expires_on, occurred_on) != :lt, do: available, else: 0

    Repo.update!(
      Ecto.Changeset.change(lot,
        unrecovered_clawback_cents: remaining_clawback,
        remaining_cents: lot.remaining_cents + add_available
      )
    )
  end

  defp insert_credit_entitlements(lot, cash_sources) do
    ordered_sources = ordered_cash_sources(cash_sources)

    {_running, _previous_bonus} =
      Enum.reduce(ordered_sources, {0, 0}, fn {payment_id, amount}, {running, previous_bonus} ->
        next_running = running + amount
        next_bonus = credit_with_bonus(next_running)
        entitlement = next_bonus - previous_bonus

        if amount > 0 do
          Repo.insert!(
            CreditLotEntitlement.changeset(%CreditLotEntitlement{}, %{
              credit_lot_id: lot.id,
              payment_operation_id: payment_id,
              amount_cents: entitlement
            })
          )
        end

        {next_running, next_bonus}
      end)
  end

  defp ordered_cash_sources(sources) do
    durable_ids = sources |> Map.keys() |> Enum.reject(&is_nil/1)

    orders =
      if durable_ids == [] do
        %{}
      else
        Repo.all(
          from record in OperationRecord,
            where: record.operation_id in ^durable_ids,
            select: {record.operation_id, record.id}
        )
        |> Map.new()
      end

    sources
    |> Enum.sort_by(fn
      {nil, _} -> {0, 0}
      {id, _} -> {1, Map.get(orders, id, @max_integer)}
    end)
  end

  defp insert_entry(group, kind, amount, occurred_on, operation_id) do
    Repo.insert!(
      Entry.changeset(%Entry{}, %{
        group_id: group.group_id,
        kind: kind,
        amount_cents: amount,
        occurred_on: occurred_on,
        operation_id: operation_id
      })
    )
  end

  defp apply_cash_adjustment(operation, action) do
    operation_id = Map.get(operation, "operation_id")
    payment_operation_id = Map.get(operation, "payment_operation_id")

    if not valid_identifier?(operation_id) or not valid_identifier?(payment_operation_id) do
      rejected(operation_id, "invalid_operation")
    else
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil ->
          reject!({:rejected, rejected(operation_id, "operation_not_found")})

        target_record ->
          payment = Repo.get(CashPayment, payment_operation_id)

          group_id =
            if target_record.operation_type == "record_cash_payment" do
              (payment && payment.group_id) || target_record.submission["group_id"] ||
                target_record.result["group_id"]
            end

          group = if valid_identifier?(group_id), do: Repo.get(Group, group_id), else: nil

          if group && Map.has_key?(operation, "expected_revision") &&
               operation["expected_revision"] !== group.revision do
            reject!(
              {:rejected,
               rejected(operation_id, "stale_revision", %{
                 group_id: group.group_id,
                 expected_revision: operation["expected_revision"],
                 actual_revision: group.revision
               })}
            )
          end

          if action == :reduce do
            reduce_payment_cash(operation, target_record, payment, group)
          else
            charge_back_payment(operation, target_record, payment, group)
          end
      end
    end
  end

  defp reduce_payment_cash(operation, target_record, payment, group) do
    operation_id = operation["operation_id"]

    if not applied_cash_payment?(target_record, payment) or is_nil(group) or
         payment.held_cents <= 0 do
      reject!({:rejected, rejected(operation_id, "payment_not_reducible")})
    end

    unless Map.has_key?(operation, "amount_cents") do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    amount = operation["amount_cents"]

    if not (is_integer(amount) and amount > 0) do
      reject!({:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})})
    end

    if amount > payment.held_cents do
      reject!(
        {:rejected,
         rejected(operation_id, "reduction_exceeds_held_cash", %{group_id: group.group_id})}
      )
    end

    remove_held_cash(payment.payment_operation_id, amount)

    update_cash_payment!(payment.payment_operation_id, %{
      held_cents: payment.held_cents - amount,
      reduced_cents: payment.reduced_cents + amount
    })

    insert_entry(group, "cash_reduced", amount, accounting_date(operation), operation_id)

    revision = group.revision + 1
    updated_group = update_group_totals(group, revision)

    %{
      payment_operation_id: payment.payment_operation_id,
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents:
        updated_group.deposit_due_cents - updated_group.deposit_paid_cents,
      revision: revision
    }
  end

  defp charge_back_payment(operation, target_record, payment, group) do
    operation_id = operation["operation_id"]

    if not applied_cash_payment?(target_record, payment) or is_nil(group) or
         payment.charged_back_cents > 0 or payment.recorded_cents <= payment.reduced_cents do
      reject!({:rejected, rejected(operation_id, "payment_not_chargeable")})
    end

    charged_back = payment.recorded_cents - payment.reduced_cents
    remove_held_cash(payment.payment_operation_id, payment.held_cents)
    revoke_payment_credit(payment.payment_operation_id)

    update_cash_payment!(payment.payment_operation_id, %{
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: payment.charged_back_cents + charged_back
    })

    date = accounting_date(operation)

    if payment.refunded_cents > 0,
      do: insert_entry(group, "refund_reversal", payment.refunded_cents, date, operation_id)

    if payment.retained_cents > 0,
      do: insert_entry(group, "retention_reversal", payment.retained_cents, date, operation_id)

    if payment.converted_to_credit_cents > 0,
      do:
        insert_entry(
          group,
          "cash_to_credit_reversal",
          payment.converted_to_credit_cents,
          date,
          operation_id
        )

    insert_entry(group, "cash_charged_back", charged_back, date, operation_id)

    revision = group.revision + 1
    updated_group = update_group_totals(group, revision)

    %{
      payment_operation_id: payment.payment_operation_id,
      group_id: group.group_id,
      charged_back_cents: charged_back,
      outstanding_deposit_cents:
        updated_group.deposit_due_cents - updated_group.deposit_paid_cents,
      revision: revision
    }
  end

  defp applied_cash_payment?(record, %CashPayment{} = payment) do
    record.operation_type == "record_cash_payment" and record.result["status"] == "applied" and
      payment.recorded_cents > 0
  end

  defp applied_cash_payment?(_record, _payment), do: false

  defp revoke_payment_credit(payment_operation_id) do
    Repo.all(
      from entitlement in CreditLotEntitlement,
        where: entitlement.payment_operation_id == ^payment_operation_id,
        order_by: [asc: entitlement.id]
    )
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)
      unrecovered = entitlement.amount_cents - removed

      Repo.update!(
        Ecto.Changeset.change(lot,
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + unrecovered
        )
      )
    end)
  end

  defp remove_held_cash(_payment_operation_id, 0), do: :ok

  defp remove_held_cash(payment_operation_id, amount) do
    allocations =
      Repo.all(
        from allocation in RoomCashAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where: allocation.payment_operation_id == ^payment_operation_id,
          order_by: [desc: room.position, desc: allocation.id],
          select: {allocation, room}
      )

    {_remaining, _} =
      Enum.reduce_while(allocations, {amount, :ok}, fn {allocation, room}, {remaining, _} ->
        removed = min(remaining, allocation.amount_cents)

        if removed == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update!(
            Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - removed)
          )
        end

        Repo.update!(
          Ecto.Changeset.change(room,
            deposit_paid_cents: room.deposit_paid_cents - removed,
            cash_paid_cents: room.cash_paid_cents - removed
          )
        )

        next_remaining = remaining - removed
        if next_remaining == 0, do: {:halt, {0, :ok}}, else: {:cont, {next_remaining, :ok}}
      end)
  end

  defp update_cash_payment!(payment_id, changes) do
    payment = Repo.get!(CashPayment, payment_id)

    resolved =
      Enum.reduce(changes, %{}, fn
        {field, {:increment, amount}}, acc ->
          Map.put(acc, field, Map.fetch!(payment, field) + amount)

        {field, {:decrement, amount}}, acc ->
          Map.put(acc, field, Map.fetch!(payment, field) - amount)

        {field, value}, acc ->
          Map.put(acc, field, value)
      end)

    Repo.update!(Ecto.Changeset.change(payment, resolved))
  end

  defp accounting_date(operation) do
    case parse_date(Map.get(operation, "occurred_on")) do
      {:ok, date} -> date
      :error -> Date.utc_today()
    end
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: [asc: room.position, asc: room.id]
    )
  end

  defp allocate_funding_to_rooms(group, amount, :cash, payment_operation_id) do
    active_rooms(group.group_id)
    |> Enum.reduce_while(amount, fn room, remaining ->
      available = max(room.deposit_due_cents - room.deposit_paid_cents, 0)
      allocated = min(available, remaining)

      if allocated > 0 do
        Repo.update!(
          Ecto.Changeset.change(room,
            deposit_paid_cents: room.deposit_paid_cents + allocated,
            cash_paid_cents: room.cash_paid_cents + allocated
          )
        )

        Repo.insert!(
          RoomCashAllocation.changeset(%RoomCashAllocation{}, %{
            group_id: group.group_id,
            room_id: room.room_id,
            payment_operation_id: payment_operation_id,
            amount_cents: allocated
          })
        )
      end

      next = remaining - allocated
      if next == 0, do: {:halt, 0}, else: {:cont, next}
    end)
  end

  defp allocate_credit_to_rooms(group, lots, amount, operation_id) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      consumed = min(lot.remaining_cents, remaining)

      if consumed > 0 do
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - consumed))
        allocate_credit_funding_to_rooms(group, consumed, operation_id, lot.id)
      end

      next = remaining - consumed
      if next == 0, do: {:halt, 0}, else: {:cont, next}
    end)
  end

  defp allocate_credit_funding_to_rooms(group, amount, operation_id, lot_id) do
    active_rooms(group.group_id)
    |> Enum.reduce_while(amount, fn room, remaining ->
      available = max(room.deposit_due_cents - room.deposit_paid_cents, 0)
      allocated = min(available, remaining)

      if allocated > 0 do
        Repo.update!(
          Ecto.Changeset.change(room,
            deposit_paid_cents: room.deposit_paid_cents + allocated,
            credit_paid_cents: room.credit_paid_cents + allocated
          )
        )

        Repo.insert!(
          CreditAllocation.changeset(%CreditAllocation{}, %{
            group_id: group.group_id,
            room_id: room.room_id,
            credit_lot_id: lot_id,
            source_operation_id: operation_id,
            amount_cents: allocated
          })
        )
      end

      next = remaining - allocated
      if next == 0, do: {:halt, 0}, else: {:cont, next}
    end)
  end

  defp update_group_totals(group, revision) do
    rooms = active_rooms(group.group_id)

    attrs = %{
      status: if(rooms == [], do: "cancelled", else: "active"),
      lodging_total_cents: Enum.reduce(rooms, 0, &(&1.lodging_total_cents + &2)),
      deposit_due_cents: Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2)),
      deposit_paid_cents: Enum.reduce(rooms, 0, &(&1.deposit_paid_cents + &2)),
      cash_paid_cents: Enum.reduce(rooms, 0, &(&1.cash_paid_cents + &2)),
      credit_paid_cents: Enum.reduce(rooms, 0, &(&1.credit_paid_cents + &2)),
      revision: revision
    }

    Repo.update!(Ecto.Changeset.change(group, attrs))
  end

  defp credit_shortfall_total do
    lots = Repo.all(from lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)

    Enum.reduce(lots, 0, fn lot, total ->
      applied =
        Repo.one(
          from allocation in CreditAllocation,
            join: group in Group,
            on: allocation.group_id == group.group_id,
            where: allocation.credit_lot_id == ^lot.id and group.status == "active",
            select: sum(allocation.amount_cents)
        ) || 0

      total + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp available_credit_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^on and
            lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp available_credit_total(on) do
    Repo.one(
      from lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.issued_on <= ^on and lot.expires_on >= ^on,
        select: sum(lot.remaining_cents)
    ) || 0
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until(_policy_version, _arrival_on), do: nil

  defp credit_with_bonus(cash_cents) do
    cash_cents + div(cash_cents * 10 + 50, 100)
  end

  defp calculate_rooms(rooms, arrival_on, departure_on, rate_plan) when is_list(rooms) do
    nights = Date.diff(departure_on, arrival_on)

    parsed =
      Enum.map(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
          lodging = nights * rate
          deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

          if lodging <= @max_integer do
            {:ok,
             %{room_id: room_id, nightly_rate_cents: rate, lodging: lodging, deposit_due: deposit}}
          else
            :error
          end

        _ ->
          :error
      end)

    if rooms == [] or Enum.any?(parsed, &(&1 == :error)) do
      {:error, :invalid_rooms}
    else
      values = Enum.map(parsed, fn {:ok, room} -> room end)
      room_ids = Enum.map(values, & &1.room_id)
      lodging_total = Enum.reduce(values, 0, &(&1.lodging + &2))

      if length(Enum.uniq(room_ids)) != length(room_ids) or lodging_total > @max_integer do
        {:error, :invalid_rooms}
      else
        deposit_due =
          case rate_plan do
            "flexible" -> Enum.reduce(values, 0, &(&1.deposit_due + &2))
            "advance_purchase" -> lodging_total
          end

        if deposit_due > @max_integer do
          {:error, :invalid_rooms}
        else
          {:ok, values, lodging_total, deposit_due}
        end
      end
    end
  end

  defp calculate_rooms(_rooms, _arrival_on, _departure_on, _rate_plan),
    do: {:error, :invalid_rooms}

  defp parse_rate_plan("flexible"), do: {:ok, "flexible"}
  defp parse_rate_plan("advance_purchase"), do: {:ok, "advance_purchase"}
  defp parse_rate_plan(_), do: {:error, :invalid_rate_plan}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp rejected(operation_id, code, extra \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, extra)
  end

  defp reject!({:rejected, result}), do: throw({:handled_rejection, result})

  defp operation_type(operation), do: if(is_binary(operation["type"]), do: operation["type"])

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
