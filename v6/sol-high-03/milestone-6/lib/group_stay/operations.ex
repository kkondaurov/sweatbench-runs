defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and exposes the resulting group, credit, and ledger state.

  Every identified operation owns a database transaction containing both its domain effects and
  durable idempotency record. Handled rejections commit their audit record without leaking domain
  changes, while unexpected failures roll the entire operation back.
  """

  import Ecto.Query

  alias GroupStay.{
    AllocationCounter,
    CashAllocation,
    CashDisposition,
    CashPayment,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    FinanceReporting,
    Group,
    PartnerOperation,
    Repo,
    Room
  }

  @rate_plans ~w(flexible advance_purchase)
  @active "active"
  @cancelled "cancelled"
  @flex_30_start ~D[2027-01-01]
  @max_sqlite_integer 9_223_372_036_854_775_807

  def apply_batch(operations) when is_list(operations),
    do: Enum.map(operations, &apply_operation/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> group |> Repo.preload(:rooms) |> serialize_group()
    end
  end

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> restore_result(operation.result)
    end
  end

  def get_payment(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        {:error, :operation_not_found}

      _operation ->
        case Repo.get(CashPayment, operation_id) do
          nil -> {:error, :payment_not_reconcilable}
          payment -> {:ok, serialize_payment(payment)}
        end
    end
  end

  def reporting_date(nil), do: {:ok, Date.utc_today()}
  def reporting_date(value), do: parse_date(value)

  def ledger, do: ledger(Date.utc_today())

  def guest_credit(guest_id, %Date{} = on) do
    lots =
      from(lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  def ledger(%Date{} = on) do
    {:ok, totals} = Repo.transaction(fn -> ledger_snapshot(on) end)
    totals
  end

  defp ledger_snapshot(on) do
    {held, refunded, retained, converted, reduced, charged_back} =
      from(group in Group,
        select: {
          group.cash_held_cents,
          group.cash_refunded_cents,
          group.cash_retained_cents,
          group.cash_converted_to_credit_cents,
          group.cash_reduced_cents,
          group.cash_charged_back_cents
        }
      )
      |> Repo.all()
      |> Enum.reduce({0, 0, 0, 0, 0, 0}, fn {group_held, group_refunded, group_retained,
                                             group_converted, group_reduced, group_charged},
                                            {held, refunded, retained, converted, reduced,
                                             charged} ->
        {
          held + group_held,
          refunded + group_refunded,
          retained + group_retained,
          converted + group_converted,
          reduced + group_reduced,
          charged + group_charged
        }
      end)

    available_credit =
      from(lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
        select: lot.remaining_cents
      )
      |> Repo.all()
      |> Enum.sum()

    applied_credit =
      from(allocation in CreditAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: room.status == @active,
        select: allocation.amount_cents
      )
      |> Repo.all()
      |> Enum.sum()

    credit_shortfall =
      from(lot in CreditLot,
        where: lot.unrecovered_clawback_cents > 0,
        left_join: allocation in CreditAllocation,
        on: allocation.credit_lot_id == lot.id,
        left_join: room in Room,
        on: room.id == allocation.room_id and room.status == @active,
        group_by: [lot.id, lot.unrecovered_clawback_cents],
        select:
          fragment(
            "MIN(?, COALESCE(SUM(CASE WHEN ? IS NOT NULL THEN ? ELSE 0 END), 0))",
            lot.unrecovered_clawback_cents,
            room.id,
            allocation.amount_cents
          )
      )
      |> Repo.all()
      |> Enum.sum()

    %{
      cash_held_cents: held,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      cash_reduced_cents: reduced,
      cash_charged_back_cents: charged_back,
      credit_shortfall_cents: credit_shortfall,
      credit_liability_cents: available_credit + applied_credit
    }
  end

  defp apply_operation(operation) when is_map(operation) do
    operation = normalize_json(operation)

    case operation_id(operation) do
      operation_id when is_binary(operation_id) -> transact_operation(operation_id, operation)
      nil -> execute_operation(operation)
    end
  end

  defp apply_operation(_operation), do: reject(%{}, "invalid_operation")

  defp transact_operation(operation_id, operation) do
    transaction = fn ->
      case Repo.get_by(PartnerOperation, operation_id: operation_id) do
        nil ->
          result = execute_operation(operation)

          %PartnerOperation{
            operation_id: operation_id,
            operation_type: submitted_type(operation),
            submitted_payload: operation,
            result: normalize_json(result)
          }
          |> Repo.insert!()

          result

        %PartnerOperation{submitted_payload: ^operation, result: result} ->
          restore_result(result)

        %PartnerOperation{} ->
          reject(operation, "operation_id_conflict")
      end
    end

    case Repo.transaction(transaction, mode: :immediate) do
      {:ok, result} -> result
    end
  end

  defp execute_operation(operation) do
    case operation["type"] do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> with_group(operation, &record_cash_payment/2)
      "apply_hotel_credit" -> with_group(operation, &apply_hotel_credit/2)
      "reschedule_group" -> with_group(operation, &reschedule_group/2)
      "cancel_group" -> with_group(operation, &cancel_group/2)
      "cancel_rooms" -> with_group(operation, &cancel_rooms/2)
      "transfer_deposit" -> transfer_deposit(operation)
      "reduce_cash_payment" -> with_payment_group(operation, :reduce)
      "charge_back_payment" -> with_payment_group(operation, :charge_back)
      "start_finance_reporting" -> start_finance_reporting(operation)
      _unknown -> reject(operation, "invalid_operation")
    end
  end

  defp start_finance_reporting(operation) do
    cond do
      not valid_identifier?(operation["operation_id"]) ->
        reject(operation, "invalid_operation")

      true ->
        case parse_date(operation["starts_on"]) do
          {:ok, starts_on} ->
            case FinanceReporting.start(starts_on, operation["operation_id"]) do
              :ok -> applied(operation, starts_on: Date.to_iso8601(starts_on))
              {:error, :already_started} -> reject(operation, "reporting_already_started")
            end

          :error ->
            reject(operation, "invalid_reporting_date")
        end
    end
  end

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_operation), do: nil

  defp normalize_json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp restore_result(result) do
    Map.new(result, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp open_group(operation) do
    with :ok <- require_open_fields(operation) do
      case Repo.get(Group, operation["group_id"]) do
        nil -> validate_and_open(operation)
        _group -> reject(operation, "group_already_exists")
      end
    else
      :error -> reject(operation, "invalid_operation")
    end
  end

  defp validate_and_open(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.before?(arrival_on, departure_on) do
      validate_open_rate_and_rooms(operation, booked_on, arrival_on, departure_on)
    else
      _invalid -> reject(operation, "invalid_stay")
    end
  end

  defp validate_open_rate_and_rooms(operation, booked_on, arrival_on, departure_on) do
    cond do
      operation["rate_plan"] not in @rate_plans ->
        reject(operation, "invalid_rate_plan")

      not valid_rooms?(operation["rooms"], Date.diff(departure_on, arrival_on)) ->
        reject(operation, "invalid_rooms")

      true ->
        case calculate_totals(
               operation["rooms"],
               Date.diff(departure_on, arrival_on),
               operation["rate_plan"]
             ) do
          {:ok, lodging_total_cents, deposit_due_cents} ->
            persist_group(
              operation,
              booked_on,
              arrival_on,
              departure_on,
              lodging_total_cents,
              deposit_due_cents
            )

          :error ->
            reject(operation, "invalid_rooms")
        end
    end
  end

  defp persist_group(
         operation,
         booked_on,
         arrival_on,
         departure_on,
         lodging_total_cents,
         deposit_due_cents
       ) do
    group = %Group{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      policy_version: policy_for(operation["rate_plan"], booked_on),
      status: @active,
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents
    }

    case Repo.insert(group) do
      {:ok, group} ->
        operation["rooms"]
        |> Enum.with_index()
        |> Enum.each(fn {room, position} ->
          lodging = Date.diff(departure_on, arrival_on) * room["nightly_rate_cents"]

          %Room{
            group_id: group.group_id,
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            position: position,
            status: @active,
            lodging_total_cents: lodging,
            deposit_due_cents: room_deposit(lodging, group.rate_plan)
          }
          |> Repo.insert!()
        end)

        applied(operation,
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        )

      {:error, _changeset} ->
        reject(operation, "group_already_exists")
    end
  end

  defp with_group(operation, apply_fun) do
    with :ok <- require_group_operation_fields(operation),
         %Group{} = group <- Repo.get(Group, operation["group_id"]) do
      with :ok <- check_expected_revision(operation, group) do
        apply_fun.(operation, group)
      else
        {:stale, expected_revision} ->
          operation
          |> reject("stale_revision")
          |> Map.merge(%{
            group_id: group.group_id,
            expected_revision: expected_revision,
            actual_revision: group.revision
          })

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      :error -> reject(operation, "invalid_operation")
      nil -> reject(operation, "group_not_found")
    end
  end

  defp transfer_deposit(operation) do
    with :ok <- require_transfer_fields(operation),
         %Group{} = source <- Repo.get(Group, operation["source_group_id"]),
         %Group{} = destination <- Repo.get(Group, operation["destination_group_id"]) do
      with :ok <- check_source_revision(operation, source),
           :ok <- check_destination_revision(operation, destination) do
        validate_and_transfer(operation, source, destination)
      else
        {:source_stale, expected_revision} ->
          stale_rejection(operation, source, expected_revision)

        {:destination_stale, expected_revision} ->
          stale_rejection(operation, destination, expected_revision)

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      :error ->
        reject(operation, "invalid_operation")

      nil ->
        missing_id =
          if Repo.get(Group, operation["source_group_id"]),
            do: operation["destination_group_id"],
            else: operation["source_group_id"]

        operation
        |> reject("group_not_found")
        |> Map.put(:group_id, missing_id)
    end
  end

  defp validate_and_transfer(operation, source, destination) do
    amount = operation["amount_cents"]

    cond do
      source.status != @active ->
        operation |> reject("group_not_active") |> Map.put(:group_id, source.group_id)

      destination.status != @active ->
        operation |> reject("group_not_active") |> Map.put(:group_id, destination.group_id)

      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        reject(operation, "invalid_transfer")

      not valid_occurred_on?(operation) ->
        reject(operation, "invalid_operation")

      not valid_payment_amount?(amount) ->
        reject(operation, "invalid_amount")

      amount > source.deposit_paid_cents ->
        reject(operation, "transfer_exceeds_held_funding")

      amount > outstanding_deposit(destination) ->
        reject(operation, "transfer_exceeds_outstanding")

      true ->
        apply_transfer(operation, source, destination, amount)
    end
  end

  defp apply_transfer(operation, source, destination, amount) do
    chunks = draw_transfer_chunks(source.group_id, amount)
    {cash, credit} = allocate_transfer_chunks(destination.group_id, chunks)

    chunks
    |> Enum.flat_map(fn
      %{kind: :cash, payment_operation_id: nil} -> []
      %{kind: :cash, payment_operation_id: payment_id} -> [payment_id]
      %{kind: :credit} -> []
    end)
    |> Enum.uniq()
    |> Enum.each(fn payment_id ->
      payment = Repo.get!(CashPayment, payment_id)

      payment
      |> Ecto.Changeset.change(participated_in_transfer: true)
      |> Repo.update!()
    end)

    source =
      source
      |> Ecto.Changeset.change(%{
        deposit_paid_cents: source.deposit_paid_cents - amount,
        cash_paid_cents: source.cash_paid_cents - cash,
        credit_paid_cents: source.credit_paid_cents - credit,
        cash_held_cents: source.cash_held_cents - cash,
        revision: source.revision + 1
      })
      |> Repo.update!()

    destination =
      destination
      |> Ecto.Changeset.change(%{
        deposit_paid_cents: destination.deposit_paid_cents + amount,
        cash_paid_cents: destination.cash_paid_cents + cash,
        credit_paid_cents: destination.credit_paid_cents + credit,
        cash_held_cents: destination.cash_held_cents + cash,
        revision: destination.revision + 1
      })
      |> Repo.update!()

    FinanceReporting.record_cash(
      operation,
      source.property_id,
      "cash_transferred_out",
      cash
    )

    FinanceReporting.record_cash(
      operation,
      destination.property_id,
      "cash_transferred_in",
      cash
    )

    applied(operation,
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents: outstanding_deposit(source),
      destination_outstanding_deposit_cents: outstanding_deposit(destination),
      source_revision: source.revision,
      destination_revision: destination.revision
    )
  end

  defp stale_rejection(operation, group, expected_revision) do
    operation
    |> reject("stale_revision")
    |> Map.merge(%{
      group_id: group.group_id,
      expected_revision: expected_revision,
      actual_revision: group.revision
    })
  end

  defp check_destination_revision(operation, destination) do
    case Map.fetch(operation, "destination_expected_revision") do
      :error -> :ok
      {:ok, expected} when is_integer(expected) and expected == destination.revision -> :ok
      {:ok, expected} when is_integer(expected) -> {:destination_stale, expected}
      {:ok, _invalid} -> :error
    end
  end

  defp check_source_revision(operation, source) do
    case check_expected_revision(operation, source) do
      {:stale, expected} -> {:source_stale, expected}
      result -> result
    end
  end

  defp with_payment_group(operation, action) do
    with :ok <- require_payment_target_fields(operation, action),
         %PartnerOperation{} <-
           Repo.get_by(PartnerOperation, operation_id: operation["payment_operation_id"]) do
      case Repo.get(CashPayment, operation["payment_operation_id"]) do
        nil ->
          payment_action_rejection(operation, action)

        %CashPayment{} = payment ->
          group = Repo.get!(Group, payment.group_id)

          case check_expected_revision(operation, group) do
            :ok ->
              apply_payment_action(operation, group, payment, action)

            {:stale, expected_revision} ->
              operation
              |> reject("stale_revision")
              |> Map.merge(%{
                group_id: group.group_id,
                expected_revision: expected_revision,
                actual_revision: group.revision
              })

            :error ->
              reject(operation, "invalid_operation")
          end
      end
    else
      :error -> reject(operation, "invalid_operation")
      nil -> reject(operation, "operation_not_found")
    end
  end

  defp apply_payment_action(operation, group, payment, :reduce),
    do: reduce_cash_payment(operation, group, payment)

  defp apply_payment_action(operation, group, payment, :charge_back),
    do: charge_back_payment(operation, group, payment)

  defp payment_action_rejection(operation, :reduce),
    do: reject(operation, "payment_not_reducible")

  defp payment_action_rejection(operation, :charge_back),
    do: reject(operation, "payment_not_chargeable")

  defp reduce_cash_payment(operation, group, payment) do
    amount = operation["amount_cents"]

    cond do
      not valid_occurred_on?(operation) ->
        reject(operation, "invalid_operation")

      not valid_payment_amount?(amount) ->
        reject(operation, "invalid_amount")

      payment.held_cents == 0 ->
        reject(operation, "payment_not_reducible")

      amount > payment.held_cents ->
        reject(operation, "reduction_exceeds_held_cash")

      true ->
        removals = remove_held_allocations(payment.payment_operation_id, amount)

        payment
        |> Ecto.Changeset.change(%{
          held_cents: payment.held_cents - amount,
          reduced_cents: payment.reduced_cents + amount
        })
        |> Repo.update!()

        groups =
          update_correction_groups(removals, group.group_id, %{
            group.group_id => %{cash_reduced_cents: amount}
          })

        Enum.each(removals, fn {group_id, removed} ->
          corrected_group = Map.fetch!(groups, group_id)

          FinanceReporting.record_cash(
            operation,
            corrected_group.property_id,
            "cash_reduced",
            removed
          )
        end)

        group = Map.fetch!(groups, group.group_id)

        applied(operation,
          payment_operation_id: payment.payment_operation_id,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision
        )
    end
  end

  defp charge_back_payment(operation, group, payment) do
    chargeable =
      payment.charged_back_cents == 0 and payment.recorded_cents > payment.reduced_cents

    cond do
      not valid_occurred_on?(operation) ->
        reject(operation, "invalid_operation")

      not chargeable ->
        reject(operation, "payment_not_chargeable")

      true ->
        held = payment.held_cents
        charged_back = payment.recorded_cents - payment.reduced_cents

        removals =
          if held > 0, do: remove_held_allocations(payment.payment_operation_id, held), else: %{}

        dispositions =
          from(disposition in CashDisposition,
            where: disposition.payment_operation_id == ^payment.payment_operation_id
          )
          |> Repo.all()

        classification_changes =
          chargeback_classification_changes(dispositions, group.group_id, charged_back)

        Enum.each(dispositions, &Repo.delete!/1)
        revoke_credit_entitlements(payment.payment_operation_id, operation)

        payment
        |> Ecto.Changeset.change(%{
          held_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: charged_back
        })
        |> Repo.update!()

        groups = update_correction_groups(removals, group.group_id, classification_changes)

        Enum.each(removals, fn {group_id, removed} ->
          corrected_group = Map.fetch!(groups, group_id)

          FinanceReporting.record_cash(
            operation,
            corrected_group.property_id,
            "cash_charged_back",
            removed
          )
        end)

        Enum.each(dispositions, fn disposition ->
          disposition_group = Map.fetch!(groups, disposition.group_id)
          property_id = disposition_group.property_id

          FinanceReporting.record_cash(
            operation,
            property_id,
            cash_reporting_kind(disposition.kind),
            -disposition.amount_cents
          )

          FinanceReporting.record_cash(
            operation,
            property_id,
            "cash_charged_back",
            disposition.amount_cents
          )
        end)

        group = Map.fetch!(groups, group.group_id)

        applied(operation,
          payment_operation_id: payment.payment_operation_id,
          group_id: group.group_id,
          charged_back_cents: charged_back,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision
        )
    end
  end

  defp record_cash_payment(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      not valid_occurred_on?(operation) ->
        reject(operation, "invalid_operation")

      not valid_payment_amount?(operation["amount_cents"]) ->
        reject(operation, "invalid_amount")

      operation["amount_cents"] > outstanding_deposit(group) ->
        reject(operation, "payment_exceeds_outstanding")

      true ->
        amount = operation["amount_cents"]

        payment =
          %CashPayment{
            payment_operation_id: operation["operation_id"],
            group_id: group.group_id,
            recorded_cents: amount,
            held_cents: amount
          }
          |> Repo.insert!()

        allocate_cash(group, amount, payment.payment_operation_id)

        group =
          group
          |> Ecto.Changeset.change(%{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount,
            cash_held_cents: group.cash_held_cents + amount,
            revision: group.revision + 1
          })
          |> Repo.update!()

        FinanceReporting.record_cash(
          operation,
          group.property_id,
          "cash_received",
          amount
        )

        applied(operation,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision
        )
    end
  end

  defp apply_hotel_credit(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      not valid_occurred_on?(operation) ->
        reject(operation, "invalid_operation")

      not valid_payment_amount?(operation["amount_cents"]) ->
        reject(operation, "invalid_amount")

      operation["amount_cents"] > outstanding_deposit(group) ->
        reject(operation, "payment_exceeds_outstanding")

      true ->
        {:ok, occurred_on} = parse_date(operation["occurred_on"])
        fund_group_with_credit(operation, group, occurred_on)
    end
  end

  defp fund_group_with_credit(operation, group, occurred_on) do
    lots =
      from(lot in CreditLot,
        where:
          lot.guest_id == ^group.guest_id and lot.remaining_cents > 0 and
            lot.expires_on >= ^occurred_on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    amount = operation["amount_cents"]

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      reject(operation, "insufficient_credit")
    else
      consume_credit_lots(operation, lots, group.group_id, amount)

      group =
        group
        |> Ecto.Changeset.change(%{
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount,
          revision: group.revision + 1
        })
        |> Repo.update!()

      applied(operation,
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      )
    end
  end

  defp consume_credit_lots(operation, lots, group_id, amount) do
    rooms = active_rooms(group_id)

    {lot_chunks, 0} =
      Enum.reduce_while(lots, {[], amount}, fn lot, {chunks, remaining} ->
        consumed = min(lot.remaining_cents, remaining)

        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - consumed)
        |> Repo.update!()

        FinanceReporting.pause_credit_expiry(operation, lot, consumed)

        next = {chunks ++ [{lot.id, consumed}], remaining - consumed}
        if remaining - consumed == 0, do: {:halt, next}, else: {:cont, next}
      end)

    allocate_credit_chunks(rooms, group_id, lot_chunks)
  end

  defp reschedule_group(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
             true <- Date.after?(new_arrival_on, occurred_on),
             {:ok, new_departure_on} <-
               shift_departure(new_arrival_on, Date.diff(group.departure_on, group.arrival_on)) do
          group =
            group
            |> Ecto.Changeset.change(%{
              arrival_on: new_arrival_on,
              departure_on: new_departure_on,
              revision: group.revision + 1
            })
            |> Repo.update!()

          applied(operation,
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(group.arrival_on),
            new_departure_on: Date.to_iso8601(group.departure_on),
            policy_version: group.policy_version,
            refundable_until: serialize_date(refundable_until(group)),
            revision: group.revision
          )
        else
          _invalid -> reject(operation, "invalid_stay")
        end
    end
  end

  defp cancel_group(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      not valid_refund_method?(operation) ->
        reject(operation, "invalid_operation")

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} ->
            settle_cancellation(
              operation,
              group,
              active_rooms(group.group_id),
              occurred_on,
              :group
            )

          :error ->
            reject(operation, "invalid_operation")
        end
    end
  end

  defp cancel_rooms(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      not valid_refund_method?(operation) ->
        reject(operation, "invalid_operation")

      not valid_cancelled_rooms?(operation["room_ids"], group.group_id) ->
        reject(operation, "invalid_rooms")

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} ->
            room_ids = MapSet.new(operation["room_ids"])

            rooms =
              Enum.filter(active_rooms(group.group_id), &MapSet.member?(room_ids, &1.room_id))

            settle_cancellation(operation, group, rooms, occurred_on, :rooms)

          :error ->
            reject(operation, "invalid_operation")
        end
    end
  end

  defp valid_refund_method?(operation) do
    not Map.has_key?(operation, "refund_method") or
      operation["refund_method"] in ["cash", "hotel_credit"]
  end

  defp settle_cancellation(operation, group, rooms, occurred_on, result_kind) do
    refundable = refundable?(group, occurred_on)
    refund_method = operation["refund_method"] || "cash"

    if not refundable and refund_method == "hotel_credit" do
      reject(operation, "refund_method_not_available")
    else
      apply_cancellation_settlement(
        operation,
        group,
        rooms,
        occurred_on,
        refundable,
        refund_method,
        result_kind
      )
    end
  end

  defp apply_cancellation_settlement(
         operation,
         group,
         rooms,
         occurred_on,
         refundable,
         refund_method,
         result_kind
       ) do
    room_database_ids = Enum.map(rooms, & &1.id)
    all_active_rooms_selected = length(rooms) == active_room_count(group.group_id)

    allocations =
      from(allocation in CreditAllocation,
        where: allocation.room_id in ^room_database_ids,
        preload: [:credit_lot]
      )
      |> Repo.all()

    if refundable do
      restore_credit_allocations(operation, allocations, occurred_on)
    else
      FinanceReporting.record_credit(
        operation,
        "credit_consumed",
        Enum.sum(Enum.map(allocations, & &1.amount_cents))
      )

      Enum.each(allocations, &Repo.delete!/1)
    end

    cash_allocations =
      from(allocation in CashAllocation,
        where: allocation.room_id in ^room_database_ids,
        order_by: [asc: allocation.allocation_order]
      )
      |> Repo.all()

    cash = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      cancellation_cash_settlement(cash, refundable, refund_method)

    if credit_issued_cents > 0 do
      lot =
        %CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation["operation_id"],
          remaining_cents: credit_issued_cents,
          expires_on: Date.add(occurred_on, 365)
        }
        |> Repo.insert!()

      FinanceReporting.record_credit_issued(operation, lot, credit_issued_cents)

      create_credit_entitlements(lot, cash_allocations)
    end

    settle_cash_allocations(cash_allocations, group.group_id, refundable, refund_method)

    Enum.each(cash_allocations, &Repo.delete!/1)
    Enum.each(rooms, &cancel_room/1)

    lodging = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
    due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))
    cash_paid = Enum.sum(Enum.map(rooms, & &1.cash_paid_cents))
    credit_paid = Enum.sum(Enum.map(rooms, & &1.credit_paid_cents))
    status = if all_active_rooms_selected, do: @cancelled, else: @active

    group =
      group
      |> Ecto.Changeset.change(%{
        status: status,
        lodging_total_cents: group.lodging_total_cents - lodging,
        deposit_due_cents: group.deposit_due_cents - due,
        deposit_paid_cents: group.deposit_paid_cents - cash_paid - credit_paid,
        cash_paid_cents: group.cash_paid_cents - cash_paid,
        credit_paid_cents: group.credit_paid_cents - credit_paid,
        cash_held_cents: group.cash_held_cents - cash,
        cash_refunded_cents: group.cash_refunded_cents + refunded_cents,
        cash_retained_cents: group.cash_retained_cents + retained_cents,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()

    FinanceReporting.record_cash(
      operation,
      group.property_id,
      "cash_refunded",
      refunded_cents
    )

    FinanceReporting.record_cash(
      operation,
      group.property_id,
      "cash_retained",
      retained_cents
    )

    FinanceReporting.record_cash(
      operation,
      group.property_id,
      "cash_converted_to_credit",
      converted_cents
    )

    fields = [
      group_id: group.group_id,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents,
      revision: group.revision
    ]

    fields =
      if result_kind == :rooms,
        do: Keyword.put(fields, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
        else: fields

    applied(operation, fields)
  end

  defp restore_credit_allocations(operation, allocations, occurred_on) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {_lot_id, lot_allocations} ->
      lot = lot_allocations |> hd() |> Map.fetch!(:credit_lot)
      restored_cents = Enum.sum(Enum.map(lot_allocations, & &1.amount_cents))

      absorbed = min(restored_cents, lot.unrecovered_clawback_cents)
      available = restored_cents - absorbed

      FinanceReporting.restore_credit(operation, lot, available, absorbed)

      if Date.compare(lot.expires_on, occurred_on) in [:gt, :eq] do
        lot
        |> Ecto.Changeset.change(%{
          remaining_cents: lot.remaining_cents + available,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
        })
        |> Repo.update!()
      else
        lot
        |> Ecto.Changeset.change(
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
        )
        |> Repo.update!()
      end
    end)

    Enum.each(allocations, &Repo.delete!/1)
  end

  defp cancellation_cash_settlement(cash, true, "cash"), do: {cash, 0, 0, 0}

  defp cancellation_cash_settlement(cash, true, "hotel_credit") do
    {0, 0, cash, cash + round_percentage(cash, 10)}
  end

  defp cancellation_cash_settlement(cash, false, "cash"), do: {0, cash, 0, 0}

  defp draw_transfer_chunks(group_id, amount) do
    cash =
      from(allocation in CashAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: room.group_id == ^group_id and room.status == @active,
        select: {allocation, room}
      )
      |> Repo.all()
      |> Enum.map(fn {allocation, room} ->
        %{
          kind: :cash,
          allocation: allocation,
          room: room,
          allocation_order: allocation.allocation_order,
          payment_operation_id: allocation.payment_operation_id,
          amount_cents: allocation.amount_cents
        }
      end)

    credit =
      from(allocation in CreditAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: room.group_id == ^group_id and room.status == @active,
        select: {allocation, room}
      )
      |> Repo.all()
      |> Enum.map(fn {allocation, room} ->
        %{
          kind: :credit,
          allocation: allocation,
          room: room,
          allocation_order: allocation.allocation_order,
          credit_lot_id: allocation.credit_lot_id,
          amount_cents: allocation.amount_cents
        }
      end)

    {chunks, 0} =
      (cash ++ credit)
      |> Enum.sort_by(& &1.allocation_order, :desc)
      |> Enum.reduce_while({[], amount}, fn entry, {chunks, remaining} ->
        moved = min(entry.amount_cents, remaining)
        reduce_source_allocation(entry, moved)

        chunk =
          entry
          |> Map.drop([:allocation, :room, :allocation_order])
          |> Map.put(:amount_cents, moved)

        next = {chunks ++ [chunk], remaining - moved}
        if remaining == moved, do: {:halt, next}, else: {:cont, next}
      end)

    chunks
  end

  defp reduce_source_allocation(entry, removed) do
    paid_field = if entry.kind == :cash, do: :cash_paid_cents, else: :credit_paid_cents
    room = Repo.get!(Room, entry.room.id)

    room
    |> Ecto.Changeset.change(%{paid_field => Map.fetch!(room, paid_field) - removed})
    |> Repo.update!()

    if removed == entry.allocation.amount_cents do
      Repo.delete!(entry.allocation)
    else
      entry.allocation
      |> Ecto.Changeset.change(amount_cents: entry.allocation.amount_cents - removed)
      |> Repo.update!()
    end
  end

  defp allocate_transfer_chunks(group_id, chunks) do
    {remaining, cash, credit} =
      Enum.reduce_while(active_rooms(group_id), {chunks, 0, 0}, fn room,
                                                                   {remaining, cash, credit} ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents

        {next, room_cash, room_credit} =
          allocate_moved_chunks(room, group_id, remaining, capacity)

        if room_cash + room_credit > 0 do
          room
          |> Ecto.Changeset.change(%{
            cash_paid_cents: room.cash_paid_cents + room_cash,
            credit_paid_cents: room.credit_paid_cents + room_credit
          })
          |> Repo.update!()
        end

        state = {next, cash + room_cash, credit + room_credit}
        if next == [], do: {:halt, state}, else: {:cont, state}
      end)

    if remaining != [], do: raise("destination allocation invariant violated")
    {cash, credit}
  end

  defp allocate_moved_chunks(room, group_id, chunks, capacity),
    do: do_allocate_moved_chunks(room, group_id, chunks, capacity, 0, 0)

  defp do_allocate_moved_chunks(_room, _group_id, chunks, 0, cash, credit),
    do: {chunks, cash, credit}

  defp do_allocate_moved_chunks(_room, _group_id, [], _capacity, cash, credit),
    do: {[], cash, credit}

  defp do_allocate_moved_chunks(
         room,
         group_id,
         [%{amount_cents: amount} = chunk | rest],
         capacity,
         cash,
         credit
       ) do
    allocated = min(amount, capacity)
    allocation_order = next_allocation_order()

    case chunk.kind do
      :cash ->
        %CashAllocation{
          room_id: room.id,
          payment_operation_id: chunk.payment_operation_id,
          amount_cents: allocated,
          allocation_order: allocation_order
        }
        |> Repo.insert!()

      :credit ->
        %CreditAllocation{
          group_id: group_id,
          room_id: room.id,
          credit_lot_id: chunk.credit_lot_id,
          amount_cents: allocated,
          allocation_order: allocation_order
        }
        |> Repo.insert!()
    end

    remaining =
      if allocated == amount,
        do: rest,
        else: [%{chunk | amount_cents: amount - allocated} | rest]

    do_allocate_moved_chunks(
      room,
      group_id,
      remaining,
      capacity - allocated,
      cash + if(chunk.kind == :cash, do: allocated, else: 0),
      credit + if(chunk.kind == :credit, do: allocated, else: 0)
    )
  end

  defp allocate_cash(group, amount, payment_operation_id) do
    Enum.reduce_while(active_rooms(group.group_id), amount, fn room, remaining ->
      available = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      allocated = min(available, remaining)

      if allocated > 0 do
        %CashAllocation{
          room_id: room.id,
          payment_operation_id: payment_operation_id,
          amount_cents: allocated,
          allocation_order: next_allocation_order()
        }
        |> Repo.insert!()

        room
        |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents + allocated)
        |> Repo.update!()
      end

      if remaining == allocated, do: {:halt, 0}, else: {:cont, remaining - allocated}
    end)
  end

  defp allocate_credit_chunks(rooms, group_id, chunks) do
    Enum.reduce_while(rooms, chunks, fn room, remaining_chunks ->
      capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      {next_chunks, allocated} = consume_credit_chunks(remaining_chunks, room, group_id, capacity)

      if allocated > 0 do
        room
        |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents + allocated)
        |> Repo.update!()
      end

      if next_chunks == [], do: {:halt, []}, else: {:cont, next_chunks}
    end)
  end

  defp consume_credit_chunks(chunks, room, group_id, capacity) do
    do_consume_credit_chunks(chunks, room, group_id, capacity, 0)
  end

  defp do_consume_credit_chunks(chunks, _room, _group_id, 0, allocated),
    do: {chunks, allocated}

  defp do_consume_credit_chunks([], _room, _group_id, _capacity, allocated),
    do: {[], allocated}

  defp do_consume_credit_chunks(
         [{lot_id, amount} | rest],
         room,
         group_id,
         capacity,
         allocated
       ) do
    consumed = min(amount, capacity)

    %CreditAllocation{
      group_id: group_id,
      room_id: room.id,
      credit_lot_id: lot_id,
      amount_cents: consumed,
      allocation_order: next_allocation_order()
    }
    |> Repo.insert!()

    remaining_chunks =
      if consumed < amount, do: [{lot_id, amount - consumed} | rest], else: rest

    do_consume_credit_chunks(
      remaining_chunks,
      room,
      group_id,
      capacity - consumed,
      allocated + consumed
    )
  end

  defp next_allocation_order do
    counter = Repo.get!(AllocationCounter, 1)

    counter =
      counter
      |> Ecto.Changeset.change(last_value: counter.last_value + 1)
      |> Repo.update!()

    counter.last_value
  end

  defp remove_held_allocations(payment_operation_id, amount) do
    allocations =
      from(allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id,
        order_by: [desc: allocation.allocation_order],
        preload: [:room]
      )
      |> Repo.all()

    {final, removals} =
      Enum.reduce_while(allocations, {amount, %{}}, fn allocation, {remaining, removals} ->
        removed = min(allocation.amount_cents, remaining)
        room = Repo.get!(Room, allocation.room.id)

        room
        |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents - removed)
        |> Repo.update!()

        if removed == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          allocation
          |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - removed)
          |> Repo.update!()
        end

        removals = Map.update(removals, room.group_id, removed, &(&1 + removed))
        next = {remaining - removed, removals}
        if removed == remaining, do: {:halt, next}, else: {:cont, next}
      end)

    if final != 0, do: raise("cash allocation invariant violated")
    removals
  end

  defp chargeback_classification_changes(dispositions, addressed_group_id, charged_back) do
    dispositions
    |> Enum.reduce(%{}, fn disposition, changes ->
      field = disposition_field(disposition.kind)

      Map.update(
        changes,
        disposition.group_id,
        %{field => -disposition.amount_cents},
        fn fields ->
          Map.update(fields, field, -disposition.amount_cents, &(&1 - disposition.amount_cents))
        end
      )
    end)
    |> Map.update(
      addressed_group_id,
      %{cash_charged_back_cents: charged_back},
      &Map.update(&1, :cash_charged_back_cents, charged_back, fn current ->
        current + charged_back
      end)
    )
  end

  defp disposition_field("refunded"), do: :cash_refunded_cents
  defp disposition_field("retained"), do: :cash_retained_cents
  defp disposition_field("converted_to_credit"), do: :cash_converted_to_credit_cents

  defp cash_reporting_kind("refunded"), do: "cash_refunded"
  defp cash_reporting_kind("retained"), do: "cash_retained"
  defp cash_reporting_kind("converted_to_credit"), do: "cash_converted_to_credit"

  defp update_correction_groups(removals, addressed_group_id, classification_changes) do
    group_ids =
      removals
      |> Map.keys()
      |> Kernel.++(Map.keys(classification_changes))
      |> Kernel.++([addressed_group_id])
      |> Enum.uniq()

    Map.new(group_ids, fn group_id ->
      group = Repo.get!(Group, group_id)
      removed = Map.get(removals, group_id, 0)

      changes = %{
        deposit_paid_cents: group.deposit_paid_cents - removed,
        cash_paid_cents: group.cash_paid_cents - removed,
        cash_held_cents: group.cash_held_cents - removed,
        revision: group.revision + 1
      }

      changes =
        Enum.reduce(Map.get(classification_changes, group_id, %{}), changes, fn {field, delta},
                                                                                acc ->
          Map.put(acc, field, Map.fetch!(group, field) + delta)
        end)

      updated = group |> Ecto.Changeset.change(changes) |> Repo.update!()
      {group_id, updated}
    end)
  end

  defp settle_cash_allocations(allocations, group_id, refundable, refund_method) do
    allocations
    |> Enum.reject(&is_nil(&1.payment_operation_id))
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.each(fn {payment_operation_id, payment_allocations} ->
      amount = Enum.sum(Enum.map(payment_allocations, & &1.amount_cents))
      payment = Repo.get!(CashPayment, payment_operation_id)

      disposition =
        cond do
          refundable and refund_method == "cash" ->
            %{refunded_cents: payment.refunded_cents + amount}

          refundable and refund_method == "hotel_credit" ->
            %{converted_to_credit_cents: payment.converted_to_credit_cents + amount}

          true ->
            %{retained_cents: payment.retained_cents + amount}
        end

      kind =
        cond do
          refundable and refund_method == "cash" -> "refunded"
          refundable and refund_method == "hotel_credit" -> "converted_to_credit"
          true -> "retained"
        end

      %CashDisposition{
        payment_operation_id: payment_operation_id,
        group_id: group_id,
        kind: kind,
        amount_cents: amount
      }
      |> Repo.insert!()

      payment
      |> Ecto.Changeset.change(Map.put(disposition, :held_cents, payment.held_cents - amount))
      |> Repo.update!()
    end)
  end

  defp create_credit_entitlements(lot, allocations) do
    {contributions, _running_cash} =
      Enum.reduce(allocations, {[], 0}, fn allocation, {ordered, running_cash} ->
        key = allocation.payment_operation_id

        entitlement =
          credit_value(running_cash + allocation.amount_cents) - credit_value(running_cash)

        ordered =
          case Enum.find_index(ordered, &(elem(&1, 0) == key)) do
            nil ->
              ordered ++ [{key, entitlement}]

            index ->
              List.update_at(ordered, index, fn {^key, amount} ->
                {key, amount + entitlement}
              end)
          end

        {ordered, running_cash + allocation.amount_cents}
      end)

    Enum.each(contributions, fn {payment_operation_id, entitlement} ->
      %CreditEntitlement{
        credit_lot_id: lot.id,
        payment_operation_id: payment_operation_id,
        amount_cents: entitlement
      }
      |> Repo.insert!()
    end)
  end

  defp revoke_credit_entitlements(payment_operation_id, operation) do
    from(entitlement in CreditEntitlement,
      where:
        entitlement.payment_operation_id == ^payment_operation_id and
          entitlement.revoked == false,
      preload: [:credit_lot]
    )
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      lot = entitlement.credit_lot
      removable = min(lot.remaining_cents, entitlement.amount_cents)

      lot
      |> Ecto.Changeset.change(%{
        remaining_cents: lot.remaining_cents - removable,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - removable
      })
      |> Repo.update!()

      FinanceReporting.record_credit_revoked(operation, lot, removable)

      entitlement
      |> Ecto.Changeset.change(revoked: true)
      |> Repo.update!()
    end)
  end

  defp cancel_room(room) do
    room
    |> Ecto.Changeset.change(status: @cancelled, cash_paid_cents: 0, credit_paid_cents: 0)
    |> Repo.update!()
  end

  defp active_rooms(group_id) do
    from(room in Room,
      where: room.group_id == ^group_id and room.status == @active,
      order_by: [asc: room.position]
    )
    |> Repo.all()
  end

  defp active_room_count(group_id) do
    Repo.aggregate(
      from(room in Room, where: room.group_id == ^group_id and room.status == @active),
      :count
    )
  end

  defp valid_cancelled_rooms?(room_ids, group_id)
       when is_list(room_ids) and room_ids != [] do
    valid_ids = Enum.all?(room_ids, &valid_identifier?/1)
    distinct = Enum.uniq(room_ids) == room_ids

    valid_ids and distinct and
      Repo.aggregate(
        from(room in Room,
          where:
            room.group_id == ^group_id and room.status == @active and room.room_id in ^room_ids
        ),
        :count
      ) == length(room_ids)
  end

  defp valid_cancelled_rooms?(_room_ids, _group_id), do: false

  defp credit_value(cash), do: cash + round_percentage(cash, 10)

  defp require_open_fields(operation) do
    required =
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if required_present?(operation, required) and
         valid_identifier?(operation["operation_id"]) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      :ok
    else
      :error
    end
  end

  defp require_group_operation_fields(operation) do
    type_specific =
      case operation["type"] do
        "record_cash_payment" -> ["amount_cents"]
        "apply_hotel_credit" -> ["amount_cents"]
        "reschedule_group" -> ["new_arrival_on"]
        "cancel_group" -> []
        "cancel_rooms" -> ["room_ids"]
      end

    required = ~w(operation_id occurred_on group_id) ++ type_specific

    if required_present?(operation, required) and
         valid_identifier?(operation["operation_id"]) and
         valid_identifier?(operation["group_id"]) do
      :ok
    else
      :error
    end
  end

  defp require_payment_target_fields(operation, action) do
    type_specific = if action == :reduce, do: ["amount_cents"], else: []
    required = ~w(operation_id occurred_on payment_operation_id) ++ type_specific

    if required_present?(operation, required) and
         valid_identifier?(operation["operation_id"]) and
         valid_identifier?(operation["payment_operation_id"]) do
      :ok
    else
      :error
    end
  end

  defp require_transfer_fields(operation) do
    required =
      ~w(operation_id occurred_on source_group_id destination_group_id amount_cents)

    if required_present?(operation, required) and
         valid_identifier?(operation["operation_id"]) and
         valid_identifier?(operation["source_group_id"]) and
         valid_identifier?(operation["destination_group_id"]) do
      :ok
    else
      :error
    end
  end

  defp required_present?(operation, fields), do: Enum.all?(fields, &Map.has_key?(operation, &1))
  defp valid_identifier?(identifier), do: is_binary(identifier) and byte_size(identifier) > 0

  defp valid_rooms?(rooms, nights) when is_list(rooms) and rooms != [] do
    room_ids = Enum.map(rooms, &room_id/1)
    Enum.all?(rooms, &valid_room?(&1, nights)) and Enum.uniq(room_ids) == room_ids
  end

  defp valid_rooms?(_rooms, _nights), do: false

  defp valid_room?(room, nights) when is_map(room) do
    room_id = room["room_id"]
    rate = room["nightly_rate_cents"]

    valid_identifier?(room_id) and is_integer(rate) and rate >= 0 and
      rate <= @max_sqlite_integer and nights * rate <= @max_sqlite_integer
  end

  defp valid_room?(_room, _nights), do: false
  defp room_id(room) when is_map(room), do: room["room_id"]
  defp room_id(_room), do: nil

  defp room_deposit(lodging_cents, "flexible"), do: round_percentage(lodging_cents, 20)
  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents
  defp round_percentage(cents, percentage), do: div(cents * percentage + 50, 100)

  defp calculate_totals(rooms, nights, rate_plan) do
    {lodging_total, deposit_total} =
      Enum.reduce(rooms, {0, 0}, fn room, {lodging_sum, deposit_sum} ->
        lodging = nights * room["nightly_rate_cents"]
        deposit = room_deposit(lodging, rate_plan)
        {lodging_sum + lodging, deposit_sum + deposit}
      end)

    if lodging_total <= @max_sqlite_integer and deposit_total <= @max_sqlite_integer do
      {:ok, lodging_total, deposit_total}
    else
      :error
    end
  end

  defp valid_payment_amount?(amount),
    do: is_integer(amount) and amount > 0 and amount <= @max_sqlite_integer

  defp valid_occurred_on?(operation),
    do: match?({:ok, _date}, parse_date(operation["occurred_on"]))

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp shift_departure(new_arrival_on, stay_length) do
    {:ok, Date.add(new_arrival_on, stay_length)}
  rescue
    ArgumentError -> :error
  end

  defp check_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, expected} when is_integer(expected) and expected == group.revision -> :ok
      {:ok, expected} when is_integer(expected) -> {:stale, expected}
      {:ok, _invalid} -> :error
    end
  end

  defp outstanding_deposit(%Group{status: @active} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  defp outstanding_deposit(%Group{}), do: 0

  defp policy_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_for("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_start) in [:gt, :eq], do: "flex-30", else: "flex-14"
  end

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  defp refundable_until(%Group{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      cutoff -> Date.compare(occurred_on, cutoff) in [:lt, :eq]
    end
  end

  defp serialize_group(group) do
    active_rooms = Enum.filter(group.rooms, &(&1.status == @active))
    lodging_total = Enum.sum(Enum.map(active_rooms, & &1.lodging_total_cents))
    deposit_due = Enum.sum(Enum.map(active_rooms, & &1.deposit_due_cents))
    cash_paid = Enum.sum(Enum.map(active_rooms, & &1.cash_paid_cents))
    credit_paid = Enum.sum(Enum.map(active_rooms, & &1.credit_paid_cents))

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: serialize_date(refundable_until(group)),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      deposit_paid_cents: cash_paid + credit_paid,
      cash_paid_cents: cash_paid,
      credit_paid_cents: credit_paid,
      outstanding_deposit_cents: deposit_due - cash_paid - credit_paid
    }
  end

  defp serialize_payment(payment) do
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
      held_by_group =
        from(allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: allocation.payment_operation_id == ^payment.payment_operation_id,
          group_by: room.group_id,
          order_by: [asc: room.group_id],
          select: %{group_id: room.group_id, amount_cents: sum(allocation.amount_cents)}
        )
        |> Repo.all()

      Map.put(statement, :held_by_group, held_by_group)
    else
      statement
    end
  end

  defp serialize_date(nil), do: nil
  defp serialize_date(date), do: Date.to_iso8601(date)

  defp applied(operation, fields) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id(operation), status: "applied"})
  end

  defp reject(operation, code),
    do: %{operation_id: operation_id(operation), status: "rejected", code: code}

  defp operation_id(operation) do
    case operation["operation_id"] do
      operation_id when is_binary(operation_id) -> operation_id
      _invalid -> nil
    end
  end
end
