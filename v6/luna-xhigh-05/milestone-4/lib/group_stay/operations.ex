defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations one at a time, preserving batch order.

  Aggregate group fields are retained for compatibility with the first two
  releases. Room balances and the source-tagged accounting tables are the
  authoritative representation of funding for active rooms.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CashPayment,
    CreditEntitlement,
    Group,
    HotelCreditAllocation,
    HotelCreditLot,
    OperationRecord,
    Repo,
    Room
  }

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"

  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @new_policy_date ~D[2027-01-01]

  @target_operation_types ["reduce_cash_payment", "charge_back_payment"]

  @spec submit_batch(term()) :: {:ok, [map()]} | {:error, :invalid_batch}
  def submit_batch(operations) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def submit_batch(_operations), do: {:error, :invalid_batch}

  @spec get_group(String.t()) :: {:ok, map()} | {:error, :group_not_found}
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group |> ensure_group_accounting_for_read() |> group_view()}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  @spec get_operation(String.t()) :: {:ok, map()} | {:error, :operation_not_found}
  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, Jason.decode!(record.result_json)}
    end
  end

  def get_operation(_operation_id), do: {:error, :operation_not_found}

  @spec get_payment(String.t()) ::
          {:ok, map()} | {:error, :operation_not_found | :payment_not_reconcilable}
  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      record ->
        result = Jason.decode!(record.result_json)

        if record.operation_type != "record_cash_payment" or result["status"] != "applied" do
          {:error, :payment_not_reconcilable}
        else
          group_id = result["group_id"]

          if is_binary(group_id) do
            case Repo.get(Group, group_id) do
              nil ->
                {:error, :payment_not_reconcilable}

              group ->
                group = ensure_group_accounting_for_read(group)
                payment = Repo.get(CashPayment, payment_operation_id)

                if payment do
                  {:ok, payment_view(payment)}
                else
                  {:ok, fallback_payment_view(payment_operation_id, group, result)}
                end
            end
          else
            {:error, :payment_not_reconcilable}
          end
        end
    end
  end

  def get_payment(_payment_operation_id), do: {:error, :operation_not_found}

  @spec get_guest_credit(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :invalid_date}
  def get_guest_credit(guest_id, on \\ nil)

  def get_guest_credit(guest_id, on) when is_binary(guest_id) do
    with {:ok, as_of} <- as_of_date(on) do
      lots = available_credit_lots(guest_id, as_of)

      {:ok,
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
       }}
    end
  end

  def get_guest_credit(_guest_id, _on), do: {:error, :invalid_date}

  @spec ledger_totals(String.t() | nil) :: map() | {:error, :invalid_date}
  def ledger_totals(on \\ nil) do
    with {:ok, as_of} <- as_of_date(on) do
      Repo.transaction(fn ->
        Repo.all(Group) |> Enum.each(&ensure_room_accounting!/1)
        ledger_totals_at(as_of)
      end)
      |> unwrap_transaction()
    end
  end

  defp ledger_totals_at(as_of) do
    %{
      cash_held_cents: sum_active_room_field(:cash_paid_cents),
      cash_refunded_cents: payment_or_legacy_total(:refunded_cents),
      cash_retained_cents: payment_or_legacy_total(:retained_cents),
      cash_converted_to_credit_cents: payment_or_legacy_total(:converted_to_credit_cents),
      cash_reduced_cents: payment_or_legacy_total(:reduced_cents),
      cash_charged_back_cents: payment_or_legacy_total(:charged_back_cents),
      credit_liability_cents: credit_liability(as_of),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = value(operation, "operation_id")
    operation_type = value(operation, "type")

    if identifier?(operation_id) do
      process_durable_operation(operation, operation_id, operation_type)
    else
      process_untracked_operation(operation, operation_id, operation_type)
    end
  end

  defp process_operation(_operation), do: rejection(nil, "invalid_operation")

  defp process_untracked_operation(operation, operation_id, "open_group"),
    do: process_open_group(operation, operation_id)

  defp process_untracked_operation(operation, operation_id, operation_type),
    do: process_existing_group(operation, operation_id, operation_type)

  defp process_durable_operation(operation, operation_id, operation_type) do
    payload_json = canonical_json(operation)

    case Repo.transaction(
           fn ->
             case Repo.get_by(OperationRecord, operation_id: operation_id) do
               nil ->
                 case apply_operation(operation, operation_id, operation_type) do
                   {:ok, result} ->
                     remember_and_return(operation_id, operation_type, payload_json, result)

                   {:error, result} ->
                     remember_and_return(operation_id, operation_type, payload_json, result)
                 end

               record ->
                 if record.payload_json == payload_json do
                   Jason.decode!(record.result_json)
                 else
                   rejection(operation_id, "operation_id_conflict")
                 end
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
    end
  end

  defp apply_operation(operation, operation_id, "open_group"),
    do: apply_open_group(operation, operation_id)

  defp apply_operation(operation, operation_id, operation_type)
       when operation_type in @target_operation_types,
       do: apply_target_operation(operation, operation_id, operation_type)

  defp apply_operation(operation, operation_id, operation_type),
    do: apply_existing_group(operation, operation_id, operation_type)

  defp process_open_group(operation, operation_id) do
    group_id = value(operation, "group_id")

    cond do
      not identifier?(operation_id) ->
        rejection(operation_id, "invalid_operation")

      not identifier?(group_id) ->
        rejection(operation_id, "invalid_operation")

      true ->
        transaction_result(fn -> apply_open_group(operation, operation_id) end)
    end
  end

  defp apply_open_group(operation, operation_id) do
    group_id = value(operation, "group_id")

    cond do
      not identifier?(group_id) ->
        reject(rejection(operation_id, "invalid_operation"))

      Repo.get(Group, group_id) ->
        reject(rejection(operation_id, "group_already_exists", %{group_id: group_id}))

      true ->
        case validate_open_group(operation) do
          {:ok, attrs, rooms} ->
            group = Repo.insert!(Group.changeset(%Group{}, attrs))
            insert_rooms!(group.group_id, rooms, group)

            {:ok,
             applied("open_group", operation_id, %{
               group_id: group.group_id,
               deposit_due_cents: group.deposit_due_cents,
               revision: group.revision
             })}

          {:error, code} ->
            reject(rejection(operation_id, code, %{group_id: group_id}))
        end
    end
  end

  defp process_existing_group(operation, operation_id, operation_type) do
    if operation_type in @target_operation_types do
      if identifier?(value(operation, "payment_operation_id")) do
        transaction_result(fn ->
          apply_target_operation(operation, operation_id, operation_type)
        end)
      else
        rejection(operation_id, "invalid_operation")
      end
    else
      group_id = value(operation, "group_id")

      if not identifier?(group_id) do
        rejection(operation_id, "invalid_operation")
      else
        transaction_result(fn ->
          apply_existing_group(operation, operation_id, operation_type)
        end)
      end
    end
  end

  defp apply_existing_group(operation, operation_id, operation_type) do
    group_id = value(operation, "group_id")

    if not identifier?(group_id) do
      reject(rejection(operation_id, "invalid_operation"))
    else
      case Repo.get(Group, group_id) do
        nil ->
          reject(rejection(operation_id, "group_not_found", %{group_id: group_id}))

        group ->
          case revision_check(operation, group) do
            :ok ->
              ensure_room_accounting!(group)

              apply_existing(
                Repo.get!(Group, group.group_id),
                operation,
                operation_id,
                operation_type
              )

            {:error, stale} ->
              reject(stale)
          end
      end
    end
  end

  defp apply_target_operation(operation, operation_id, operation_type) do
    payment_operation_id = value(operation, "payment_operation_id")

    cond do
      not identifier?(operation_id) ->
        reject(rejection(operation_id, "invalid_operation"))

      not identifier?(payment_operation_id) ->
        reject(rejection(operation_id, "invalid_operation"))

      true ->
        case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
          nil ->
            reject(rejection(operation_id, "operation_not_found"))

          record ->
            target_result = Jason.decode!(record.result_json)
            group_id = target_result["group_id"]

            if not identifier?(group_id) do
              apply_target_without_group(record, operation_id, operation_type)
            else
              case Repo.get(Group, group_id) do
                nil ->
                  reject(rejection(operation_id, "group_not_found", %{group_id: group_id}))

                group ->
                  case revision_check_for_group(operation, group, operation_id) do
                    :ok ->
                      ensure_room_accounting!(group)

                      apply_existing(
                        Repo.get!(Group, group.group_id),
                        operation,
                        operation_id,
                        operation_type,
                        record
                      )

                    {:error, stale} ->
                      reject(stale)
                  end
              end
            end
        end
    end
  end

  defp apply_target_without_group(_record, operation_id, "reduce_cash_payment"),
    do: reject(rejection(operation_id, "payment_not_reducible"))

  defp apply_target_without_group(_record, operation_id, _operation_type),
    do: reject(rejection(operation_id, "payment_not_chargeable"))

  defp apply_existing(group, operation, operation_id, operation_type, target_record \\ nil) do
    case operation_type do
      "record_cash_payment" -> apply_cash_payment(group, operation, operation_id)
      "apply_hotel_credit" -> apply_hotel_credit(group, operation, operation_id)
      "reschedule_group" -> apply_reschedule(group, operation, operation_id)
      "cancel_group" -> apply_cancellation(group, operation, operation_id)
      "cancel_rooms" -> apply_room_cancellation(group, operation, operation_id)
      "reduce_cash_payment" -> apply_cash_reduction(group, operation, operation_id, target_record)
      "charge_back_payment" -> apply_chargeback(group, operation, operation_id, target_record)
      _ -> reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp apply_cash_payment(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))

          {:ok, _occurred_on} ->
            apply_cash_payment_amount(group, operation, operation_id)
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp apply_cash_payment_amount(group, operation, operation_id) do
    amount_cents = value(operation, "amount_cents")
    outstanding = outstanding_deposit(group)

    cond do
      not usable_amount?(amount_cents) ->
        reject(rejection(operation_id, "invalid_amount", %{group_id: group.group_id}))

      amount_cents > outstanding ->
        reject(
          rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})
        )

      true ->
        rooms = active_rooms(group)
        {chunks, _updated_rooms} = allocate_amount_to_rooms(rooms, amount_cents, :cash_paid_cents)
        insert_cash_allocations!(group.group_id, operation_id, chunks)
        update_rooms_from_chunks!(rooms, chunks, :cash_paid_cents)

        Repo.insert!(%CashPayment{
          payment_operation_id: operation_id,
          group_id: group.group_id,
          recorded_cents: amount_cents,
          held_cents: amount_cents,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 0,
          charged_back_cents: 0
        })

        update_group_with_totals!(group, %{revision: group.revision + 1})

        {:ok,
         applied("record_cash_payment", operation_id, %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding - amount_cents,
           revision: group.revision + 1
         })}
    end
  end

  defp apply_hotel_credit(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))

          {:ok, occurred_on} ->
            apply_hotel_credit_amount(group, operation, operation_id, occurred_on)
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp apply_hotel_credit_amount(group, operation, operation_id, occurred_on) do
    amount_cents = value(operation, "amount_cents")
    outstanding = outstanding_deposit(group)

    cond do
      not usable_amount?(amount_cents) ->
        reject(rejection(operation_id, "invalid_amount", %{group_id: group.group_id}))

      amount_cents > outstanding ->
        reject(
          rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})
        )

      true ->
        lots = available_credit_lots(group.guest_id, occurred_on)

        case credit_allocation(lots, amount_cents) do
          {:error, :insufficient_credit} ->
            reject(rejection(operation_id, "insufficient_credit", %{group_id: group.group_id}))

          {:ok, lot_chunks} ->
            rooms = active_rooms(group)

            {room_chunks, _updated_rooms} =
              allocate_amount_to_rooms(rooms, amount_cents, :credit_paid_cents)

            allocation_chunks = pair_funding_chunks(room_chunks, lot_chunks)
            insert_credit_allocations!(group.group_id, operation_id, allocation_chunks)
            update_rooms_from_chunks!(rooms, room_chunks, :credit_paid_cents)
            consume_credit_lots!(lot_chunks)
            update_group_with_totals!(group, %{revision: group.revision + 1})

            {:ok,
             applied("apply_hotel_credit", operation_id, %{
               group_id: group.group_id,
               amount_cents: amount_cents,
               outstanding_deposit_cents: outstanding - amount_cents,
               revision: group.revision + 1
             })}
        end
    end
  end

  defp apply_reschedule(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))

          {:ok, occurred_on} ->
            reschedule_from(group, operation, operation_id, occurred_on)
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp reschedule_from(group, operation, operation_id, occurred_on) do
    with {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         true <- Date.compare(new_arrival_on, occurred_on) == :gt do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)
      policy_version = group_policy_version(group)
      refundable_until = refundable_until(policy_version, new_arrival_on)

      update_group!(group, %{
        arrival_on: new_arrival_on,
        departure_on: new_departure_on,
        refundable_until: refundable_until,
        revision: group.revision + 1
      })

      {:ok,
       applied("reschedule_group", operation_id, %{
         group_id: group.group_id,
         new_arrival_on: Date.to_iso8601(new_arrival_on),
         new_departure_on: Date.to_iso8601(new_departure_on),
         policy_version: policy_version,
         refundable_until: date_value(refundable_until),
         revision: group.revision + 1
       })}
    else
      _ -> reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))
    end
  end

  defp apply_cancellation(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:ok, occurred_on} ->
            settle_selected_rooms(
              group,
              active_room_ids(group),
              operation,
              operation_id,
              occurred_on,
              false
            )

          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp apply_room_cancellation(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:ok, occurred_on} ->
            case selected_active_room_ids(group, value(operation, "room_ids")) do
              {:ok, room_ids} ->
                settle_selected_rooms(group, room_ids, operation, operation_id, occurred_on, true)

              :error ->
                reject(rejection(operation_id, "invalid_rooms", %{group_id: group.group_id}))
            end

          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp settle_selected_rooms(group, room_ids, operation, operation_id, occurred_on, partial?) do
    case refund_method(operation) do
      {:error, :invalid_refund_method} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

      {:ok, refund_method} ->
        refundable? = refundable?(group, occurred_on)

        if refund_method == "hotel_credit" and not refundable? do
          reject(
            rejection(operation_id, "refund_method_not_available", %{group_id: group.group_id})
          )
        else
          cash_rows = cash_allocations_for_rooms(group.group_id, room_ids)
          cash_contributors = cash_contributors(cash_rows)
          cash_paid_cents = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
          credit_rows = credit_allocations_for_rooms(group.group_id, room_ids)

          delete_cash_allocations!(cash_rows)
          settle_cash_contributors!(cash_contributors, refundable?, refund_method)
          settle_credit_allocations!(credit_rows, occurred_on, refundable?)

          credit_issued_cents = credit_issued(refundable?, refund_method, cash_paid_cents)

          if credit_issued_cents > 0 do
            issue_credit_lot!(
              group.guest_id,
              operation_id,
              credit_issued_cents,
              occurred_on,
              cash_contributors
            )
          end

          update_rooms_status!(group.group_id, room_ids, @cancelled)

          cancelled_room_ids =
            group
            |> rooms_for_group()
            |> Enum.filter(&(&1.room_id in room_ids))
            |> Enum.map(& &1.room_id)

          new_status =
            if active_room_ids(group.group_id, room_ids) == [], do: @cancelled, else: @active

          refunded_cents =
            if refundable? and refund_method == "cash", do: cash_paid_cents, else: 0

          retained_cents = if refundable?, do: 0, else: cash_paid_cents
          converted_cents = if credit_issued_cents > 0, do: cash_paid_cents, else: 0

          attrs = %{
            status: new_status,
            refunded_cents: integer_value(group.refunded_cents) + refunded_cents,
            retained_cents: integer_value(group.retained_cents) + retained_cents,
            cash_converted_to_credit_cents:
              integer_value(group.cash_converted_to_credit_cents) + converted_cents,
            revision: group.revision + 1
          }

          update_group_with_totals!(group, attrs)

          result_attrs = %{
            group_id: group.group_id,
            refunded_cents: refunded_cents,
            retained_cents: retained_cents,
            credit_issued_cents: credit_issued_cents,
            revision: group.revision + 1
          }

          result_attrs =
            if partial?,
              do: Map.put(result_attrs, :cancelled_room_ids, cancelled_room_ids),
              else: result_attrs

          {:ok,
           applied(
             if(partial?, do: "cancel_rooms", else: "cancel_group"),
             operation_id,
             result_attrs
           )}
        end
    end
  end

  defp apply_cash_reduction(group, operation, operation_id, target_record) do
    with {:ok, _occurred_on} <- operation_date_for_correction(operation),
         true <- applied_cash_payment_record?(target_record),
         %CashPayment{} = payment <-
           Repo.get(CashPayment, value_from_result(target_record, "operation_id")) do
      held = payment.held_cents
      amount_cents = value(operation, "amount_cents")

      cond do
        not usable_amount?(held) ->
          reject(rejection(operation_id, "payment_not_reducible", %{group_id: group.group_id}))

        not usable_amount?(amount_cents) ->
          reject(rejection(operation_id, "invalid_amount", %{group_id: group.group_id}))

        amount_cents > held ->
          reject(
            rejection(operation_id, "reduction_exceeds_held_cash", %{group_id: group.group_id})
          )

        true ->
          remove_cash_for_payment!(group.group_id, payment.payment_operation_id, amount_cents)

          payment
          |> change(
            held_cents: held - amount_cents,
            reduced_cents: payment.reduced_cents + amount_cents
          )
          |> Repo.update!()

          update_group_with_totals!(group, %{
            cash_reduced_cents: integer_value(group.cash_reduced_cents) + amount_cents,
            revision: group.revision + 1
          })

          {:ok,
           applied("reduce_cash_payment", operation_id, %{
             payment_operation_id: payment.payment_operation_id,
             group_id: group.group_id,
             amount_cents: amount_cents,
             outstanding_deposit_cents: outstanding_deposit(group),
             revision: group.revision + 1
           })}
      end
    else
      {:error, _reason} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

      false ->
        reject(rejection(operation_id, "payment_not_reducible", %{group_id: group.group_id}))

      nil ->
        reject(rejection(operation_id, "payment_not_reducible", %{group_id: group.group_id}))
    end
  end

  defp apply_chargeback(group, operation, operation_id, target_record) do
    with {:ok, _occurred_on} <- operation_date_for_correction(operation),
         true <- applied_cash_payment_record?(target_record),
         %CashPayment{} = payment <-
           Repo.get(CashPayment, value_from_result(target_record, "operation_id")),
         false <- payment.charged_back_cents > 0,
         true <- chargeable_payment?(payment) do
      charged_back_cents =
        payment.held_cents + payment.refunded_cents + payment.retained_cents +
          payment.converted_to_credit_cents

      if charged_back_cents <= 0 do
        reject(rejection(operation_id, "payment_not_chargeable", %{group_id: group.group_id}))
      else
        remove_cash_for_payment!(group.group_id, payment.payment_operation_id, payment.held_cents)
        revoke_credit_entitlements!(payment.payment_operation_id)
        update_group_after_chargeback!(group, payment, charged_back_cents)

        payment
        |> change(
          held_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: payment.charged_back_cents + charged_back_cents
        )
        |> Repo.update!()

        {:ok,
         applied("charge_back_payment", operation_id, %{
           payment_operation_id: payment.payment_operation_id,
           group_id: group.group_id,
           charged_back_cents: charged_back_cents,
           outstanding_deposit_cents: outstanding_deposit(group),
           revision: group.revision + 1
         })}
      end
    else
      {:error, _reason} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

      false ->
        reject(rejection(operation_id, "payment_not_chargeable", %{group_id: group.group_id}))

      nil ->
        reject(rejection(operation_id, "payment_not_chargeable", %{group_id: group.group_id}))
    end
  end

  defp validate_open_group(operation) do
    with {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, rate_plan} <- valid_rate_plan(value(operation, "rate_plan")),
         {:ok, rooms} <- valid_rooms(value(operation, "rooms")) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total_cents = Enum.sum(Enum.map(rooms, &(&1.nightly_rate_cents * nights)))

      deposit_due_cents =
        Enum.sum(Enum.map(rooms, &room_deposit(&1.nightly_rate_cents, nights, rate_plan)))

      policy_version = policy_version(rate_plan, booked_on)

      attrs = %{
        group_id: value(operation, "group_id"),
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version,
        refundable_until: refundable_until(policy_version, arrival_on),
        status: @active,
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        cash_reduced_cents: 0,
        cash_charged_back_cents: 0,
        room_accounting_initialized: true
      }

      {:ok, attrs, rooms}
    else
      {:error, "invalid_operation"} -> {:error, "invalid_operation"}
      {:error, "invalid_stay"} -> {:error, "invalid_stay"}
      {:error, "invalid_rooms"} -> {:error, "invalid_rooms"}
      {:error, "invalid_rate_plan"} -> {:error, "invalid_rate_plan"}
      false -> {:error, "invalid_stay"}
    end
  end

  defp valid_rate_plan(@flexible), do: {:ok, @flexible}
  defp valid_rate_plan(@advance_purchase), do: {:ok, @advance_purchase}
  defp valid_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    Enum.reduce_while(Enum.with_index(rooms), {:ok, MapSet.new(), []}, fn
      {room, position}, {:ok, room_ids, valid} when is_map(room) ->
        room_id = value(room, "room_id")
        nightly_rate_cents = value(room, "nightly_rate_cents")

        cond do
          not identifier?(room_id) ->
            {:halt, {:error, "invalid_rooms"}}

          MapSet.member?(room_ids, room_id) ->
            {:halt, {:error, "invalid_rooms"}}

          not is_integer(nightly_rate_cents) or nightly_rate_cents < 0 ->
            {:halt, {:error, "invalid_rooms"}}

          true ->
            {:cont,
             {:ok, MapSet.put(room_ids, room_id),
              [
                %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}
                | valid
              ]}}
        end

      _room, _acc ->
        {:halt, {:error, "invalid_rooms"}}
    end)
    |> case do
      {:ok, _room_ids, rooms} -> {:ok, Enum.reverse(rooms)}
      error -> error
    end
  end

  defp valid_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp required_identifier(operation, key) do
    case value(operation, key) do
      identifier when is_binary(identifier) and identifier != "" -> {:ok, identifier}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_date(operation, key) do
    case value(operation, key) do
      date when is_binary(date) ->
        case Date.from_iso8601(date) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp operation_date(operation) do
    case value(operation, "occurred_on") do
      nil ->
        {:error, "invalid_operation"}

      date when is_binary(date) ->
        case Date.from_iso8601(date) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp operation_date_for_correction(operation), do: operation_date(operation)

  defp refund_method(operation) do
    case present_value(operation, "refund_method") do
      :missing -> {:ok, "cash"}
      {:present, "cash"} -> {:ok, "cash"}
      {:present, "hotel_credit"} -> {:ok, "hotel_credit"}
      _ -> {:error, :invalid_refund_method}
    end
  end

  defp validate_operation_id(operation_id) when is_binary(operation_id) and operation_id != "",
    do: :ok

  defp validate_operation_id(_operation_id), do: {:error, "invalid_operation"}

  defp identifier?(identifier) when is_binary(identifier), do: identifier != ""
  defp identifier?(_identifier), do: false

  defp revision_check(operation, group),
    do: revision_check_for_group(operation, group, value(operation, "operation_id"))

  defp revision_check_for_group(operation, group, operation_id) do
    case present_value(operation, "expected_revision") do
      :missing ->
        :ok

      {:present, expected_revision} when expected_revision == group.revision ->
        :ok

      {:present, expected_revision} ->
        {:error,
         rejection(operation_id, "stale_revision", %{
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         })}
    end
  end

  defp transaction_result(fun) do
    case Repo.transaction(
           fn ->
             case fun.() do
               {:ok, result} -> result
               {:error, result} -> Repo.rollback({:rejected, result})
               result -> result
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, {:rejected, result}} -> result
    end
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: raise("transaction failed: #{inspect(reason)}")

  defp reject(result), do: {:error, result}

  defp update_group!(group, attrs), do: group |> Group.changeset(attrs) |> Repo.update!()

  defp update_group_with_totals!(group, attrs),
    do: update_group!(group, Map.merge(active_totals(group), attrs))

  defp insert_rooms!(group_id, rooms, group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Repo.insert_all(
      Room,
      Enum.map(rooms, fn room ->
        %{
          group_id: group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: room.position,
          status: @active,
          deposit_due_cents: room_deposit(room.nightly_rate_cents, nights, group.rate_plan),
          cash_paid_cents: 0,
          credit_paid_cents: 0
        }
      end)
    )
  end

  defp group_view(group) do
    rooms = rooms_for_group(group)
    totals = active_totals_from_rooms(group, rooms)
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
      refundable_until:
        date_value(group.refundable_until || refundable_until(policy_version, group.arrival_on)),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            lodging_total_cents:
              room.nightly_rate_cents * Date.diff(group.departure_on, group.arrival_on),
            status: room.status,
            deposit_due_cents: integer_value(room.deposit_due_cents),
            cash_paid_cents: integer_value(room.cash_paid_cents),
            credit_paid_cents: integer_value(room.credit_paid_cents)
          }
        end),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: max(totals.deposit_due_cents - totals.deposit_paid_cents, 0)
    }
  end

  defp rooms_for_group(group) do
    Repo.all(from room in Room, where: room.group_id == ^group.group_id, order_by: room.position)
  end

  defp active_rooms(group), do: Enum.filter(rooms_for_group(group), &(&1.status == @active))

  defp active_room_ids(group) when is_struct(group, Group),
    do: group |> active_rooms() |> Enum.map(& &1.room_id)

  defp active_room_ids(group_id, excluded_ids) when is_binary(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == ^@active,
        select: room.room_id
    ) -- excluded_ids
  end

  defp selected_active_room_ids(group, room_ids) when is_list(room_ids) do
    with true <- room_ids != [],
         true <- Enum.all?(room_ids, &identifier?/1),
         true <- length(Enum.uniq(room_ids)) == length(room_ids),
         rooms <- rooms_for_group(group),
         true <-
           Enum.all?(room_ids, fn room_id ->
             Enum.any?(rooms, &(&1.room_id == room_id and &1.status == @active))
           end) do
      {:ok, room_ids}
    else
      _ -> :error
    end
  end

  defp selected_active_room_ids(_group, _room_ids), do: :error

  defp active_totals(group), do: active_totals_from_rooms(group, active_rooms(group))

  defp active_totals_from_rooms(group, rooms) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    active = Enum.filter(rooms, &(&1.status == @active))

    %{
      lodging_total_cents: Enum.sum(Enum.map(active, &(&1.nightly_rate_cents * nights))),
      deposit_due_cents: Enum.sum(Enum.map(active, &integer_value(&1.deposit_due_cents))),
      deposit_paid_cents:
        Enum.sum(
          Enum.map(
            active,
            &(integer_value(&1.cash_paid_cents) + integer_value(&1.credit_paid_cents))
          )
        ),
      cash_paid_cents: Enum.sum(Enum.map(active, &integer_value(&1.cash_paid_cents))),
      credit_paid_cents: Enum.sum(Enum.map(active, &integer_value(&1.credit_paid_cents)))
    }
  end

  defp outstanding_deposit(group) do
    totals = active_totals(group)
    max(totals.deposit_due_cents - totals.deposit_paid_cents, 0)
  end

  defp sum_active_room_field(field_name) do
    Repo.one(
      from room in Room,
        where: room.status == ^@active,
        select: coalesce(sum(field(room, ^field_name)), 0)
    )
  end

  defp payment_or_legacy_total(field_name) do
    known =
      Repo.one(from payment in CashPayment, select: coalesce(sum(field(payment, ^field_name)), 0))

    group_field =
      case field_name do
        :converted_to_credit_cents -> :cash_converted_to_credit_cents
        :reduced_cents -> :cash_reduced_cents
        :charged_back_cents -> :cash_charged_back_cents
        other -> other
      end

    aggregate = sum_group_field(group_field)
    known + max(aggregate - known, 0)
  end

  defp sum_group_field(field_name),
    do: Repo.one(from group in Group, select: coalesce(sum(field(group, ^field_name)), 0))

  defp ensure_group_accounting_for_read(group) do
    if group.room_accounting_initialized do
      group
    else
      {:ok, result} =
        Repo.transaction(fn ->
          persisted = Repo.get!(Group, group.group_id)
          ensure_room_accounting!(persisted)
          Repo.get!(Group, group.group_id)
        end)

      result
    end
  end

  defp ensure_room_accounting!(%Group{room_accounting_initialized: true}), do: :ok

  defp ensure_room_accounting!(group) do
    rooms = rooms_for_group(group)
    old_credit_allocations = old_credit_allocations(group.group_id)
    funding = durable_funding(group)

    Repo.delete_all(
      from allocation in CashAllocation, where: allocation.group_id == ^group.group_id
    )

    Repo.delete_all(
      from allocation in HotelCreditAllocation, where: allocation.group_id == ^group.group_id
    )

    rooms =
      Enum.map(rooms, fn room ->
        room
        |> change(
          status: if(group.status == @active, do: @active, else: @cancelled),
          deposit_due_cents:
            room_deposit(
              room.nightly_rate_cents,
              Date.diff(group.departure_on, group.arrival_on),
              group.rate_plan
            ),
          cash_paid_cents: 0,
          credit_paid_cents: 0
        )
        |> Repo.update!()
      end)

    if group.status == @active do
      total_cash = integer_value(group.cash_paid_cents)
      recorded_cash = Enum.sum(Enum.map(funding.cash, & &1.amount_cents))
      total_credit = integer_value(group.credit_paid_cents)
      recorded_credit = Enum.sum(Enum.map(funding.credit, & &1.amount_cents))

      credit_sources = [
        {nil, max(total_credit - recorded_credit, 0)}
        | Enum.map(funding.credit, &{&1.operation_id, &1.amount_cents})
      ]

      credit_segments_by_source =
        old_credit_allocations
        |> credit_segments(total_credit, credit_sources)
        |> Enum.group_by(fn {_lot_id, source_id, _amount} -> source_id end)

      {legacy_cash_chunks, rooms} =
        allocate_amount_to_rooms(rooms, max(total_cash - recorded_cash, 0), :cash_paid_cents)

      {legacy_credit_rows, rooms} =
        allocate_credit_segments_to_rooms(rooms, Map.get(credit_segments_by_source, nil, []))

      recorded_sources =
        Enum.map(funding.cash, &Map.put(&1, :funding_type, :cash)) ++
          Enum.map(funding.credit, &Map.put(&1, :funding_type, :credit))

      {cash_rows, credit_rows, _rooms} =
        Enum.reduce(
          Enum.sort_by(recorded_sources, & &1.record_id),
          {
            Enum.map(legacy_cash_chunks, fn {room_id, amount} -> {nil, room_id, amount} end),
            legacy_credit_rows,
            rooms
          },
          fn source, {cash_rows, credit_rows, rooms} ->
            case source.funding_type do
              :cash ->
                {chunks, rooms} =
                  allocate_amount_to_rooms(rooms, source.amount_cents, :cash_paid_cents)

                {cash_rows ++
                   Enum.map(chunks, fn {room_id, amount} ->
                     {source.operation_id, room_id, amount}
                   end), credit_rows, rooms}

              :credit ->
                {chunks, rooms} =
                  allocate_credit_segments_to_rooms(
                    rooms,
                    Map.get(credit_segments_by_source, source.operation_id, [])
                  )

                {cash_rows, credit_rows ++ chunks, rooms}
            end
          end
        )

      insert_cash_allocation_rows!(group.group_id, cash_rows)
      insert_credit_allocation_rows!(group.group_id, credit_rows)

      update_rooms_from_chunks!(
        rooms_for_group(group),
        Enum.map(cash_rows, fn {_source, room_id, amount} -> {room_id, amount} end),
        :cash_paid_cents
      )

      update_rooms_from_chunks!(
        rooms_for_group(group),
        Enum.map(credit_rows, fn {_lot, _source, room_id, amount} -> {room_id, amount} end),
        :credit_paid_cents
      )

      Enum.each(funding.cash, fn source ->
        held =
          Enum.sum(
            for {source_id, _room_id, amount} <- cash_rows,
                source_id == source.operation_id,
                do: amount
          )

        ensure_cash_payment!(source, group.group_id, held)
      end)
    else
      settlement_field =
        cond do
          integer_value(group.cash_converted_to_credit_cents) > 0 -> :converted_to_credit_cents
          integer_value(group.refunded_cents) > 0 -> :refunded_cents
          integer_value(group.retained_cents) > 0 -> :retained_cents
          true -> nil
        end

      Enum.each(funding.cash, fn source ->
        ensure_settled_cash_payment!(source, group.group_id, settlement_field)
      end)
    end

    backfill_credit_entitlements!(group, funding)

    update_group!(group, %{room_accounting_initialized: true})
    :ok
  end

  defp durable_funding(group) do
    records =
      Repo.all(
        from record in OperationRecord,
          where: record.operation_type in ["record_cash_payment", "apply_hotel_credit"],
          order_by: record.id
      )

    Enum.reduce(records, %{cash: [], credit: []}, fn record, funding ->
      result = Jason.decode!(record.result_json)

      if result["status"] == "applied" and result["group_id"] == group.group_id and
           is_integer(result["amount_cents"]) do
        source = %{
          operation_id: record.operation_id,
          amount_cents: result["amount_cents"],
          record_id: record.id
        }

        case record.operation_type do
          "record_cash_payment" -> %{funding | cash: funding.cash ++ [source]}
          "apply_hotel_credit" -> %{funding | credit: funding.credit ++ [source]}
        end
      else
        funding
      end
    end)
  end

  defp old_credit_allocations(group_id) do
    Repo.all(
      from allocation in HotelCreditAllocation,
        where: allocation.group_id == ^group_id,
        order_by: allocation.id
    )
  end

  defp allocate_credit_segments_to_rooms(rooms, segments) do
    Enum.reduce(segments, {[], rooms}, fn {lot_id, source_id, amount}, {rows, rooms} ->
      {chunks, rooms} = allocate_amount_to_rooms(rooms, amount, :credit_paid_cents)

      {rows ++ Enum.map(chunks, fn {room_id, chunk} -> {lot_id, source_id, room_id, chunk} end),
       rooms}
    end)
  end

  defp credit_segments(old_allocations, total, sources) do
    source_segments = consume_source_amounts(sources, total)

    {segments, _source_segments} =
      Enum.reduce(old_allocations, {[], source_segments}, fn allocation, {segments, sources} ->
        {taken, sources} = take_source_amounts(sources, allocation.amount_cents)

        {segments ++
           Enum.map(taken, fn {source_id, amount} ->
             {allocation.credit_lot_id, source_id, amount}
           end), sources}
      end)

    segments
  end

  defp consume_source_amounts(sources, total) do
    {_remaining, used} =
      Enum.reduce_while(sources, {total, []}, fn {source_id, amount}, {remaining, used} ->
        take = min(max(amount, 0), remaining)
        used = if take > 0, do: used ++ [{source_id, take}], else: used
        if remaining - take == 0, do: {:halt, {0, used}}, else: {:cont, {remaining - take, used}}
      end)

    used
  end

  defp take_source_amounts(sources, amount), do: take_source_amounts(sources, amount, [])
  defp take_source_amounts([], _amount, taken), do: {Enum.reverse(taken), []}

  defp take_source_amounts([{source_id, available} | rest], amount, taken) do
    take = min(available, amount)

    if take == available do
      take_source_amounts(rest, amount - take, [{source_id, take} | taken])
    else
      {Enum.reverse([{source_id, take} | taken]), [{source_id, available - take} | rest]}
    end
  end

  defp allocate_amount_to_rooms(rooms, amount, field_name) do
    {chunks, updated_rooms, _remaining} =
      Enum.reduce(rooms, {[], [], amount}, fn room, {chunks, updated_rooms, remaining} ->
        available = room_capacity(room)
        used = min(max(remaining, 0), available)
        updated_room = Map.put(room, field_name, integer_value(Map.get(room, field_name)) + used)
        chunks = if used > 0, do: chunks ++ [{room.room_id, used}], else: chunks
        {chunks, updated_rooms ++ [updated_room], remaining - used}
      end)

    {chunks, updated_rooms}
  end

  defp room_capacity(room),
    do:
      max(
        integer_value(room.deposit_due_cents) - integer_value(room.cash_paid_cents) -
          integer_value(room.credit_paid_cents),
        0
      )

  defp update_rooms_from_chunks!(rooms, chunks, field_name) do
    amounts =
      Enum.reduce(chunks, %{}, fn {room_id, amount}, acc ->
        Map.update(acc, room_id, amount, &(&1 + amount))
      end)

    Enum.each(rooms, fn room ->
      amount = Map.get(amounts, room.room_id, 0)

      if amount > 0 do
        room
        |> change(%{field_name => integer_value(Map.get(room, field_name)) + amount})
        |> Repo.update!()
      end
    end)
  end

  defp insert_cash_allocations!(group_id, operation_id, chunks) do
    Repo.insert_all(
      CashAllocation,
      Enum.map(chunks, fn {room_id, amount} ->
        %{
          group_id: group_id,
          room_id: room_id,
          payment_operation_id: operation_id,
          amount_cents: amount
        }
      end)
    )
  end

  defp insert_cash_allocation_rows!(group_id, rows) do
    Repo.insert_all(
      CashAllocation,
      Enum.map(rows, fn {operation_id, room_id, amount} ->
        %{
          group_id: group_id,
          room_id: room_id,
          payment_operation_id: operation_id,
          amount_cents: amount
        }
      end)
    )
  end

  defp insert_credit_allocations!(group_id, operation_id, chunks) do
    Repo.insert_all(
      HotelCreditAllocation,
      Enum.map(chunks, fn {lot, room_id, amount} ->
        %{
          group_id: group_id,
          credit_lot_id: lot.id,
          room_id: room_id,
          operation_id: operation_id,
          amount_cents: amount
        }
      end)
    )
  end

  defp insert_credit_allocation_rows!(group_id, rows) do
    Repo.insert_all(
      HotelCreditAllocation,
      Enum.map(rows, fn {lot_id, operation_id, room_id, amount} ->
        %{
          group_id: group_id,
          credit_lot_id: lot_id,
          room_id: room_id,
          operation_id: operation_id,
          amount_cents: amount
        }
      end)
    )
  end

  defp update_rooms_status!(group_id, room_ids, status),
    do:
      Repo.update_all(
        from(room in Room, where: room.group_id == ^group_id and room.room_id in ^room_ids),
        set: [status: status]
      )

  defp cash_allocations_for_rooms(group_id, room_ids),
    do:
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids
      )

  defp credit_allocations_for_rooms(group_id, room_ids),
    do:
      Repo.all(
        from allocation in HotelCreditAllocation,
          where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids
      )

  defp delete_cash_allocations!([]), do: :ok

  defp delete_cash_allocations!(rows) do
    Repo.delete_all(
      from allocation in CashAllocation, where: allocation.id in ^Enum.map(rows, & &1.id)
    )

    :ok
  end

  defp cash_contributors(rows) do
    ids = rows |> Enum.map(& &1.payment_operation_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    order = operation_order(ids)

    rows
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.map(fn {operation_id, allocations} ->
      {operation_id, Enum.sum(Enum.map(allocations, & &1.amount_cents))}
    end)
    |> Enum.sort_by(fn {operation_id, _amount} -> source_sort_key(operation_id, order) end)
  end

  defp operation_order([]), do: %{}

  defp operation_order(ids) do
    Repo.all(
      from record in OperationRecord,
        where: record.operation_id in ^ids,
        select: {record.operation_id, record.id}
    )
    |> Map.new()
  end

  defp source_sort_key(nil, _order), do: {0, 0, ""}

  defp source_sort_key(operation_id, order),
    do: {1, Map.get(order, operation_id, 0), operation_id}

  defp settle_cash_contributors!(contributors, refundable?, refund_method) do
    Enum.each(contributors, fn
      {nil, _amount} ->
        :ok

      {operation_id, amount} ->
        settle_cash_payment!(operation_id, amount, refundable?, refund_method)
    end)
  end

  defp settle_cash_payment!(operation_id, amount, refundable?, refund_method) do
    payment = Repo.get!(CashPayment, operation_id)

    attrs =
      cond do
        refundable? and refund_method == "cash" ->
          %{refunded_cents: payment.refunded_cents + amount}

        refundable? and refund_method == "hotel_credit" ->
          %{converted_to_credit_cents: payment.converted_to_credit_cents + amount}

        true ->
          %{retained_cents: payment.retained_cents + amount}
      end

    payment |> change(Map.put(attrs, :held_cents, payment.held_cents - amount)) |> Repo.update!()
  end

  defp settle_credit_allocations!(rows, occurred_on, refundable?) do
    Enum.each(rows, fn allocation ->
      if refundable? do
        lot = Repo.get!(HotelCreditLot, allocation.credit_lot_id)
        restore_credit_amount!(lot, allocation.amount_cents, occurred_on)
      end

      Repo.delete!(allocation)
    end)
  end

  defp issue_credit_lot!(guest_id, source_operation_id, amount_cents, cancelled_on, contributors) do
    lot =
      Repo.insert!(%HotelCreditLot{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: amount_cents,
        issued_on: cancelled_on,
        expires_on: Date.add(cancelled_on, 366),
        issued_cents: amount_cents,
        unrecovered_clawback_cents: 0
      })

    {entitlements, _running_cash, _running_credit} =
      Enum.reduce(contributors, {[], 0, 0}, fn {operation_id, amount},
                                               {entitlements, running_cash, running_credit} ->
        new_running_cash = running_cash + amount
        new_running_credit = round_percentage(new_running_cash, 110)
        entitlement = new_running_credit - running_credit

        entitlements =
          if entitlement > 0,
            do: [
              %{
                credit_lot_id: lot.id,
                payment_operation_id: operation_id,
                entitlement_cents: entitlement,
                clawed_back_cents: 0
              }
              | entitlements
            ],
            else: entitlements

        {entitlements, new_running_cash, new_running_credit}
      end)

    if entitlements != [], do: Repo.insert_all(CreditEntitlement, Enum.reverse(entitlements))
    lot
  end

  defp backfill_credit_entitlements!(group, funding) do
    cancellation_records =
      Repo.all(
        from record in OperationRecord,
          where: record.operation_type in ["cancel_group", "cancel_rooms"],
          select: {record.operation_id, record.result_json}
      )

    total_cash = integer_value(group.cash_paid_cents)
    recorded_cash = Enum.sum(Enum.map(funding.cash, & &1.amount_cents))

    contributors = [
      {nil, max(total_cash - recorded_cash, 0)}
      | Enum.map(funding.cash, &{&1.operation_id, &1.amount_cents})
    ]

    Enum.each(cancellation_records, fn {operation_id, result_json} ->
      result = Jason.decode!(result_json)

      if result["status"] == "applied" and result["group_id"] == group.group_id and
           is_integer(result["credit_issued_cents"]) and result["credit_issued_cents"] > 0 do
        case Repo.get_by(HotelCreditLot, source_operation_id: operation_id) do
          nil ->
            :ok

          lot ->
            issued_cents = integer_value(lot.issued_cents)

            if Repo.exists?(
                 from entitlement in CreditEntitlement,
                   where: entitlement.credit_lot_id == ^lot.id
               ) do
              :ok
            else
              lot
              |> change(issued_cents: max(issued_cents, result["credit_issued_cents"]))
              |> Repo.update!()

              insert_credit_entitlements!(lot.id, contributors)
            end
        end
      end
    end)
  end

  defp insert_credit_entitlements!(lot_id, contributors) do
    {entitlements, _running_cash, _running_credit} =
      Enum.reduce(contributors, {[], 0, 0}, fn {operation_id, amount},
                                               {entitlements, running_cash, running_credit} ->
        new_running_cash = running_cash + amount
        new_running_credit = round_percentage(new_running_cash, 110)
        entitlement = new_running_credit - running_credit

        entitlements =
          if entitlement > 0,
            do: [
              %{
                credit_lot_id: lot_id,
                payment_operation_id: operation_id,
                entitlement_cents: entitlement,
                clawed_back_cents: 0
              }
              | entitlements
            ],
            else: entitlements

        {entitlements, new_running_cash, new_running_credit}
      end)

    if entitlements != [], do: Repo.insert_all(CreditEntitlement, Enum.reverse(entitlements))
  end

  defp credit_issued(true, "hotel_credit", cash_paid), do: round_percentage(cash_paid, 110)
  defp credit_issued(_refundable?, _refund_method, _cash_paid), do: 0

  defp refundable?(group, occurred_on) do
    case group_policy_version(group) do
      @flex_14 -> Date.compare(occurred_on, refundable_until(@flex_14, group.arrival_on)) != :gt
      @flex_30 -> Date.compare(occurred_on, refundable_until(@flex_30, group.arrival_on)) != :gt
      _ -> false
    end
  end

  defp policy_version(rate_plan, booked_on) do
    case rate_plan do
      @advance_purchase ->
        @advance_nonrefundable

      @flexible ->
        if Date.compare(booked_on, @new_policy_date) == :lt, do: @flex_14, else: @flex_30
    end
  end

  defp group_policy_version(%Group{policy_version: policy_version})
       when is_binary(policy_version), do: policy_version

  defp group_policy_version(group), do: policy_version(group.rate_plan, group.booked_on)

  defp refundable_until(@flex_14, arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until(@flex_30, arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until(@advance_nonrefundable, _arrival_on), do: nil

  defp room_deposit(nightly_rate_cents, nights, @flexible),
    do: round_percentage(nightly_rate_cents * nights, 20)

  defp room_deposit(nightly_rate_cents, nights, @advance_purchase),
    do: nightly_rate_cents * nights

  defp available_credit_lots(guest_id, as_of) do
    Repo.all(
      from lot in HotelCreditLot,
        where:
          lot.guest_id == ^guest_id and lot.issued_on <= ^as_of and lot.expires_on > ^as_of and
            lot.remaining_cents > 0,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp credit_allocation(lots, amount_cents) do
    {allocations, remaining} =
      Enum.reduce_while(lots, {[], amount_cents}, fn lot, {allocations, remaining} ->
        used = min(lot.remaining_cents, remaining)

        if used == remaining,
          do: {:halt, {[{lot, used} | allocations], 0}},
          else: {:cont, {[{lot, used} | allocations], remaining - used}}
      end)

    if remaining == 0, do: {:ok, Enum.reverse(allocations)}, else: {:error, :insufficient_credit}
  end

  defp consume_credit_lots!(allocations) do
    Enum.each(allocations, fn {lot, amount_cents} ->
      lot |> change(remaining_cents: lot.remaining_cents - amount_cents) |> Repo.update!()
    end)
  end

  defp pair_funding_chunks(room_chunks, lot_chunks),
    do: pair_funding_chunks(room_chunks, lot_chunks, [])

  defp pair_funding_chunks([], _lots, result), do: Enum.reverse(result)
  defp pair_funding_chunks(_rooms, [], result), do: Enum.reverse(result)

  defp pair_funding_chunks([{room_id, room_amount} | rooms], [{lot, lot_amount} | lots], result) do
    used = min(room_amount, lot_amount)
    result = [{lot, room_id, used} | result]

    cond do
      room_amount == lot_amount ->
        pair_funding_chunks(rooms, lots, result)

      room_amount < lot_amount ->
        pair_funding_chunks(rooms, [{lot, lot_amount - used} | lots], result)

      true ->
        pair_funding_chunks([{room_id, room_amount - used} | rooms], lots, result)
    end
  end

  defp restore_credit_amount!(lot, amount_cents, occurred_on) do
    absorbed = min(integer_value(lot.unrecovered_clawback_cents), amount_cents)
    remaining = amount_cents - absorbed
    expires_after = Date.compare(lot.expires_on, occurred_on) == :gt

    lot
    |> change(
      remaining_cents: lot.remaining_cents + if(expires_after, do: remaining, else: 0),
      unrecovered_clawback_cents: integer_value(lot.unrecovered_clawback_cents) - absorbed
    )
    |> Repo.update!()
  end

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from lot in HotelCreditLot,
          where: lot.issued_on <= ^as_of and lot.expires_on > ^as_of and lot.remaining_cents > 0,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from allocation in HotelCreditAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where: room.status == ^@active,
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + applied
  end

  defp credit_shortfall do
    HotelCreditLot
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      applied =
        Repo.one(
          from allocation in HotelCreditAllocation,
            join: room in Room,
            on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
            where: allocation.credit_lot_id == ^lot.id and room.status == ^@active,
            select: coalesce(sum(allocation.amount_cents), 0)
        )

      total + min(integer_value(lot.unrecovered_clawback_cents), applied)
    end)
  end

  defp revoke_credit_entitlements!(payment_operation_id) do
    entitlements =
      Repo.all(
        from entitlement in CreditEntitlement,
          where: entitlement.payment_operation_id == ^payment_operation_id,
          order_by: entitlement.id
      )

    Enum.each(entitlements, fn entitlement ->
      removable = max(entitlement.entitlement_cents - entitlement.clawed_back_cents, 0)
      lot = Repo.get!(HotelCreditLot, entitlement.credit_lot_id)
      removed = min(removable, lot.remaining_cents)
      unrecovered = removable - removed

      lot
      |> change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: integer_value(lot.unrecovered_clawback_cents) + unrecovered
      )
      |> Repo.update!()

      entitlement
      |> change(clawed_back_cents: entitlement.clawed_back_cents + removed)
      |> Repo.update!()
    end)
  end

  defp remove_cash_for_payment!(_group_id, _payment_operation_id, 0), do: :ok

  defp remove_cash_for_payment!(group_id, payment_operation_id, amount_cents) do
    rows =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and
              allocation.payment_operation_id == ^payment_operation_id,
          order_by: [desc: room.position, desc: allocation.id],
          select: allocation
      )

    {remaining, _removed} =
      Enum.reduce(rows, {amount_cents, 0}, fn allocation, {remaining, removed} ->
        take = min(remaining, allocation.amount_cents)

        if take > 0 do
          if take == allocation.amount_cents,
            do: Repo.delete!(allocation),
            else:
              allocation |> change(amount_cents: allocation.amount_cents - take) |> Repo.update!()

          room = Repo.get_by!(Room, group_id: group_id, room_id: allocation.room_id)

          room
          |> change(cash_paid_cents: integer_value(room.cash_paid_cents) - take)
          |> Repo.update!()
        end

        {remaining - take, removed + take}
      end)

    if remaining > 0, do: raise("cash allocation invariant violated")
    :ok
  end

  defp update_group_after_chargeback!(group, payment, charged_back_cents) do
    update_group_with_totals!(group, %{
      refunded_cents: max(integer_value(group.refunded_cents) - payment.refunded_cents, 0),
      retained_cents: max(integer_value(group.retained_cents) - payment.retained_cents, 0),
      cash_converted_to_credit_cents:
        max(
          integer_value(group.cash_converted_to_credit_cents) - payment.converted_to_credit_cents,
          0
        ),
      cash_charged_back_cents: integer_value(group.cash_charged_back_cents) + charged_back_cents,
      revision: group.revision + 1
    })
  end

  defp applied_cash_payment_record?(record),
    do:
      record.operation_type == "record_cash_payment" and
        Jason.decode!(record.result_json)["status"] == "applied"

  defp chargeable_payment?(payment),
    do:
      payment.held_cents + payment.refunded_cents + payment.retained_cents +
        payment.converted_to_credit_cents > 0

  defp value_from_result(record, key), do: Jason.decode!(record.result_json)[key]

  defp payment_view(payment) do
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

  defp fallback_payment_view(payment_operation_id, group, result) do
    payment_view(%CashPayment{
      payment_operation_id: payment_operation_id,
      group_id: group.group_id,
      recorded_cents: result["amount_cents"] || 0,
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    })
  end

  defp ensure_cash_payment!(source, group_id, held) do
    if is_nil(Repo.get(CashPayment, source.operation_id)) do
      Repo.insert!(%CashPayment{
        payment_operation_id: source.operation_id,
        group_id: group_id,
        recorded_cents: source.amount_cents,
        held_cents: held,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0
      })
    end
  end

  defp ensure_settled_cash_payment!(source, group_id, settlement_field) do
    if is_nil(Repo.get(CashPayment, source.operation_id)) do
      attrs = %{
        payment_operation_id: source.operation_id,
        group_id: group_id,
        recorded_cents: source.amount_cents,
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0
      }

      attrs =
        if settlement_field,
          do: Map.put(attrs, settlement_field, source.amount_cents),
          else: attrs

      Repo.insert!(struct(CashPayment, attrs))
    end
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: 0

  defp as_of_date(nil), do: {:ok, Date.utc_today()}

  defp as_of_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp as_of_date(_date), do: {:error, :invalid_date}

  defp date_value(nil), do: nil
  defp date_value(date), do: Date.to_iso8601(date)

  defp usable_amount?(amount_cents), do: is_integer(amount_cents) and amount_cents > 0
  defp round_percentage(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)

  defp remember_operation!(operation_id, operation_type, payload_json, result) do
    %OperationRecord{}
    |> OperationRecord.changeset(%{
      operation_id: operation_id,
      operation_type: if(is_binary(operation_type), do: operation_type),
      payload_json: payload_json,
      result_json: Jason.encode!(result)
    })
    |> Repo.insert!()
  end

  defp remember_and_return(operation_id, operation_type, payload_json, result) do
    remember_operation!(operation_id, operation_type, payload_json, result)
    result
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {json_key(key), canonical_value(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  defp canonical_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {json_key(key), canonical_value(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value), do: value

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)

  defp applied(_type, operation_id, attrs),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, attrs)

  defp rejection(operation_id, code, attrs \\ %{}),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, attrs)

  defp value(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, String.to_atom(key)) -> Map.get(map, String.to_atom(key))
      true -> nil
    end
  end

  defp present_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:present, Map.get(map, String.to_atom(key))}
      true -> :missing
    end
  end
end
