defmodule GroupStay.Groups do
  @moduledoc "Reservation, deposit, and finance operations for GroupStay."

  import Ecto.Query

  alias GroupStay.Groups.{
    CreditLot,
    Group,
    GroupCashAllocation,
    GroupCreditAllocation,
    LedgerEntry,
    PartnerOperation,
    PaymentCreditEntitlement,
    Room
  }

  alias GroupStay.Repo

  @max_integer 9_223_372_036_854_775_807

  def process_batch(operations) when is_list(operations),
    do: Enum.map(operations, &process_operation/1)

  def get_operation_result(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        nights = Date.diff(group.departure_on, group.arrival_on)

        rooms =
          Repo.all(
            from room in Room,
              where: room.group_id == ^group.group_id,
              order_by: room.position
          )

        cash_by_room = allocations_by_room(GroupCashAllocation, group.group_id)
        credit_by_room = allocations_by_room(GroupCreditAllocation, group.group_id)

        room_data =
          Enum.map(rooms, fn room ->
            active? = room.status == "active"
            cash = Map.get(cash_by_room, room.id, 0)
            credit = Map.get(credit_by_room, room.id, 0)

            %{
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              status: room.status,
              deposit_due_cents: if(active?, do: room.deposit_due_cents, else: 0),
              cash_paid_cents: if(active?, do: cash, else: 0),
              credit_paid_cents: if(active?, do: credit, else: 0)
            }
          end)

        active_rooms = Enum.filter(rooms, &(&1.status == "active"))

        lodging_total =
          Enum.reduce(active_rooms, 0, fn room, sum ->
            sum + nights * room.nightly_rate_cents
          end)

        deposit_due = Enum.reduce(active_rooms, 0, &(&1.deposit_due_cents + &2))
        cash_paid = Enum.reduce(active_rooms, 0, &(Map.get(cash_by_room, &1.id, 0) + &2))
        credit_paid = Enum.reduce(active_rooms, 0, &(Map.get(credit_by_room, &1.id, 0) + &2))
        deposit_paid = cash_paid + credit_paid

        %{
          group_id: group.group_id,
          guest_id: group.guest_id,
          property_id: group.property_id,
          booked_on: Date.to_iso8601(group.booked_on),
          arrival_on: Date.to_iso8601(group.arrival_on),
          departure_on: Date.to_iso8601(group.departure_on),
          rate_plan: group.rate_plan,
          policy_version: group.policy_version,
          refundable_until: refundable_until(group),
          status: group.status,
          revision: group.revision,
          rooms: room_data,
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          deposit_paid_cents: deposit_paid,
          cash_paid_cents: cash_paid,
          credit_paid_cents: credit_paid,
          outstanding_deposit_cents: max(deposit_due - deposit_paid, 0)
        }
    end
  end

  def guest_credit(guest_id, on_date \\ Date.utc_today()) do
    lots = available_credit_lots(guest_id, on_date)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
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

  def ledger_totals(on_date \\ Date.utc_today()) do
    totals =
      Repo.all(
        from entry in LedgerEntry,
          group_by: entry.entry_type,
          select: {entry.entry_type, sum(entry.amount_cents)}
      )
      |> Map.new()

    held =
      Repo.one(from allocation in GroupCashAllocation, select: sum(allocation.amount_cents)) || 0

    available_credit =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on_date,
          select: sum(lot.remaining_cents)
      ) || 0

    applied_credit =
      Repo.one(
        from allocation in GroupCreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active",
          select: sum(allocation.amount_cents)
      ) || 0

    shortfall =
      Repo.all(from lot in CreditLot, select: {lot.id, lot.unrecovered_clawback_cents})
      |> Enum.reduce(0, fn {lot_id, clawback}, sum ->
        applied =
          Repo.one(
            from allocation in GroupCreditAllocation,
              join: group in Group,
              on: group.group_id == allocation.group_id,
              where: allocation.credit_lot_id == ^lot_id and group.status == "active",
              select: sum(allocation.amount_cents)
          ) || 0

        sum + min(clawback, applied)
      end)

    %{
      cash_held_cents: held,
      cash_refunded_cents: Map.get(totals, "cash_refunded", 0) || 0,
      cash_retained_cents: Map.get(totals, "cash_retained", 0) || 0,
      cash_converted_to_credit_cents: Map.get(totals, "cash_converted_to_credit", 0) || 0,
      cash_reduced_cents: Map.get(totals, "cash_reduced", 0) || 0,
      cash_charged_back_cents: Map.get(totals, "cash_charged_back", 0) || 0,
      credit_liability_cents: available_credit + applied_credit,
      credit_shortfall_cents: shortfall
    }
  end

  def payment_statement(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      %PartnerOperation{
        operation_type: "record_cash_payment",
        result: %{"status" => "applied"} = result
      } = operation ->
        recorded = result["amount_cents"]

        if is_integer(recorded) and is_binary(result["group_id"]) do
          entries = payment_dispositions(payment_operation_id)

          held =
            Repo.one(
              from allocation in GroupCashAllocation,
                where: allocation.payment_operation_id == ^payment_operation_id,
                select: sum(allocation.amount_cents)
            ) || 0

          statement = %{
            payment_operation_id: operation.operation_id,
            original_group_id: result["group_id"],
            recorded_cents: recorded,
            held_cents: held,
            refunded_cents: Map.get(entries, "cash_refunded", 0),
            retained_cents: Map.get(entries, "cash_retained", 0),
            converted_to_credit_cents: Map.get(entries, "cash_converted_to_credit", 0),
            reduced_cents: Map.get(entries, "cash_reduced", 0),
            charged_back_cents: Map.get(entries, "cash_charged_back", 0)
          }

          statement =
            if operation.transferred_funding do
              held_by_group =
                Repo.all(
                  from allocation in GroupCashAllocation,
                    where: allocation.payment_operation_id == ^payment_operation_id,
                    group_by: allocation.group_id,
                    order_by: allocation.group_id,
                    select: {allocation.group_id, sum(allocation.amount_cents)}
                )
                |> Enum.map(fn {group_id, amount} ->
                  %{group_id: group_id, amount_cents: amount}
                end)

              Map.put(statement, :held_by_group, held_by_group)
            else
              statement
            end

          {:ok, statement}
        else
          {:error, :payment_not_reconcilable}
        end

      %PartnerOperation{} ->
        {:error, :payment_not_reconcilable}
    end
  end

  defp allocations_by_room(schema, group_id) do
    Repo.all(
      from allocation in schema,
        where: allocation.group_id == ^group_id,
        group_by: allocation.room_id,
        select: {allocation.room_id, sum(allocation.amount_cents)}
    )
    |> Map.new()
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id),
      do: process_idempotently(operation, operation_id),
      else: rejection(operation_id, "invalid_operation")
  end

  defp process_operation(_), do: rejection(nil, "invalid_operation")

  defp process_idempotently(operation, operation_id) do
    case Repo.transaction(
           fn ->
             case Repo.get_by(PartnerOperation, operation_id: operation_id) do
               %PartnerOperation{submitted_content: submitted, result: result} ->
                 if submitted == operation,
                   do: result,
                   else: rejection(operation_id, "operation_id_conflict")

               nil ->
                 result = operation |> apply_operation(operation_id) |> normalize_result()

                 Repo.insert!(
                   PartnerOperation.changeset(%PartnerOperation{}, %{
                     operation_id: operation_id,
                     operation_type: operation_type(operation),
                     submitted_content: operation,
                     result: result
                   })
                 )

                 result
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp apply_operation(operation, operation_id) do
    case Map.get(operation, "type") do
      "open_group" -> open_group(operation, operation_id)
      "record_cash_payment" -> record_cash_payment(operation, operation_id)
      "reschedule_group" -> reschedule_group(operation, operation_id)
      "cancel_group" -> cancel_group(operation, operation_id)
      "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id)
      "cancel_rooms" -> cancel_rooms(operation, operation_id)
      "reduce_cash_payment" -> reduce_cash_payment(operation, operation_id)
      "charge_back_payment" -> charge_back_payment(operation, operation_id)
      "transfer_deposit" -> transfer_deposit(operation, operation_id)
      _ -> rejection(operation_id, "invalid_operation")
    end
  end

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp normalize_result(result), do: result |> Jason.encode!() |> Jason.decode!()

  defp open_group(operation, operation_id) do
    group_id = Map.get(operation, "group_id")

    if not valid_identifier?(group_id) do
      rejection(operation_id, "invalid_operation")
    else
      unwrap_operation_result(fn ->
        if Repo.get(Group, group_id) do
          {:error, rejection(operation_id, "group_already_exists", %{group_id: group_id})}
        else
          case open_attributes(operation) do
            {:error, code} ->
              {:error, rejection(operation_id, code)}

            {:ok, attrs, room_attrs} ->
              case Repo.insert(Group.changeset(%Group{}, attrs)) do
                {:ok, _group} ->
                  Enum.each(room_attrs, fn room ->
                    Repo.insert!(Room.changeset(%Room{}, Map.put(room, :group_id, group_id)))
                  end)

                  {:ok,
                   applied(operation_id, %{
                     group_id: group_id,
                     deposit_due_cents: attrs.deposit_due_cents,
                     revision: 1
                   })}

                {:error, changeset} ->
                  if Keyword.has_key?(changeset.errors, :group_id),
                    do:
                      {:error,
                       rejection(operation_id, "group_already_exists", %{group_id: group_id})},
                    else: {:error, rejection(operation_id, "invalid_operation")}
              end
          end
        end
      end)
    end
  end

  defp record_cash_payment(operation, operation_id) do
    with {:ok, group_id} <- operation_group_id(operation) do
      unwrap_operation_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            {:error, rejection(operation_id, "group_not_found", %{group_id: group_id})}

          group ->
            with :ok <- check_revision(operation, group, operation_id),
                 :ok <- active_group(group, operation_id),
                 {:ok, amount} <- payment_amount(operation),
                 {:ok, occurred_on} <- operation_date(operation) do
              outstanding = group.deposit_due_cents - group.deposit_paid_cents

              if amount > outstanding do
                {:error,
                 rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group_id})}
              else
                case update_group(
                       group,
                       %{
                         deposit_paid_cents: group.deposit_paid_cents + amount,
                         cash_paid_cents: group.cash_paid_cents + amount
                       },
                       operation_id
                     ) do
                  :ok ->
                    allocate_cash_to_rooms!(group, amount, operation_id)
                    insert_ledger_entry!(group_id, "cash_held", amount, occurred_on, operation_id)

                    {:ok,
                     applied(operation_id, %{
                       group_id: group_id,
                       amount_cents: amount,
                       outstanding_deposit_cents: outstanding - amount,
                       revision: group.revision + 1
                     })}

                  {:error, result} ->
                    {:error, result}
                end
              end
            else
              {:error, result} when is_map(result) -> {:error, result}
              {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
            end
        end
      end)
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp reschedule_group(operation, operation_id) do
    with {:ok, group_id} <- operation_group_id(operation) do
      unwrap_operation_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            {:error, rejection(operation_id, "group_not_found", %{group_id: group_id})}

          group ->
            with :ok <- check_revision(operation, group, operation_id),
                 :ok <- active_group(group, operation_id),
                 {:ok, occurred_on} <- operation_date(operation),
                 {:ok, new_arrival} <- date_field(operation, "new_arrival_on"),
                 true <- Date.compare(new_arrival, occurred_on) == :gt,
                 {:ok, new_departure} <-
                   shifted_date(group.departure_on, Date.diff(new_arrival, group.arrival_on)) do
              case update_group(
                     group,
                     %{arrival_on: new_arrival, departure_on: new_departure},
                     operation_id
                   ) do
                :ok ->
                  {:ok,
                   applied(operation_id, %{
                     group_id: group_id,
                     new_arrival_on: Date.to_iso8601(new_arrival),
                     new_departure_on: Date.to_iso8601(new_departure),
                     policy_version: group.policy_version,
                     refundable_until:
                       date_json(refundable_until_for(group.policy_version, new_arrival)),
                     revision: group.revision + 1
                   })}

                {:error, result} ->
                  {:error, result}
              end
            else
              {:error, result} when is_map(result) -> {:error, result}
              {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
              false -> {:error, rejection(operation_id, "invalid_stay", %{group_id: group_id})}
              :error -> {:error, rejection(operation_id, "invalid_stay", %{group_id: group_id})}
            end
        end
      end)
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp cancel_group(operation, operation_id) do
    with {:ok, group_id} <- operation_group_id(operation) do
      unwrap_operation_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            {:error, rejection(operation_id, "group_not_found", %{group_id: group_id})}

          group ->
            with :ok <- check_revision(operation, group, operation_id),
                 :ok <- active_group(group, operation_id),
                 {:ok, occurred_on} <- operation_date(operation),
                 {:ok, refund_method} <- refund_method(operation),
                 refundable? <- refundable_on?(group, occurred_on),
                 :ok <- refund_method_allowed(refund_method, refundable?, operation_id, group_id) do
              rooms = active_rooms(group_id)

              case settle_rooms(
                     group,
                     rooms,
                     occurred_on,
                     refund_method,
                     refundable?,
                     operation_id
                   ) do
                {:ok, settlement} ->
                  {:ok,
                   applied(operation_id, %{
                     group_id: group_id,
                     refunded_cents: settlement.refunded_cents,
                     retained_cents: settlement.retained_cents,
                     credit_issued_cents: settlement.credit_issued_cents,
                     revision: group.revision + 1
                   })}

                {:error, result} ->
                  {:error, result}
              end
            else
              {:error, result} when is_map(result) -> {:error, result}
              {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
            end
        end
      end)
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp cancel_rooms(operation, operation_id) do
    with {:ok, group_id} <- operation_group_id(operation) do
      unwrap_operation_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            {:error, rejection(operation_id, "group_not_found", %{group_id: group_id})}

          group ->
            with :ok <- check_revision(operation, group, operation_id),
                 :ok <- active_group(group, operation_id),
                 {:ok, occurred_on} <- operation_date(operation),
                 {:ok, refund_method} <- refund_method(operation),
                 refundable? <- refundable_on?(group, occurred_on),
                 :ok <- refund_method_allowed(refund_method, refundable?, operation_id, group_id),
                 {:ok, rooms} <- selected_active_rooms(operation, group_id) do
              case settle_rooms(
                     group,
                     rooms,
                     occurred_on,
                     refund_method,
                     refundable?,
                     operation_id
                   ) do
                {:ok, settlement} ->
                  {:ok,
                   applied(operation_id, %{
                     group_id: group_id,
                     cancelled_room_ids: Enum.map(rooms, & &1.room_id),
                     refunded_cents: settlement.refunded_cents,
                     retained_cents: settlement.retained_cents,
                     credit_issued_cents: settlement.credit_issued_cents,
                     revision: group.revision + 1
                   })}

                {:error, result} ->
                  {:error, result}
              end
            else
              {:error, result} when is_map(result) -> {:error, result}
              {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
            end
        end
      end)
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp settle_rooms(group, rooms, occurred_on, refund_method, refundable?, operation_id) do
    room_ids = Enum.map(rooms, & &1.id)
    cash_allocations = cash_allocations_for_rooms(group.group_id, room_ids)
    credit_allocations = credit_allocations_for_rooms(group.group_id, room_ids)
    cash_amount = Enum.reduce(cash_allocations, 0, &(&1.amount_cents + &2))
    credit_amount = Enum.reduce(credit_allocations, 0, &(&1.amount_cents + &2))
    cancelled_due = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))
    cancelled_lodging = Enum.reduce(rooms, 0, &(room_lodging(group, &1) + &2))

    active_count =
      Repo.aggregate(
        from(room in Room, where: room.group_id == ^group.group_id and room.status == "active"),
        :count
      )

    remaining_count = active_count - length(rooms)

    cash_refunded = if refundable? and refund_method == "cash", do: cash_amount, else: 0
    cash_retained = if refundable?, do: 0, else: cash_amount

    credit_issued =
      if refundable? and refund_method == "hotel_credit",
        do: credit_issue_amount(cash_amount),
        else: 0

    if credit_issued > @max_integer do
      {:error, rejection(operation_id, "invalid_amount", %{group_id: group.group_id})}
    else
      group_attrs = %{
        status: if(remaining_count == 0, do: "cancelled", else: "active"),
        lodging_total_cents: max(group.lodging_total_cents - cancelled_lodging, 0),
        deposit_due_cents: max(group.deposit_due_cents - cancelled_due, 0),
        deposit_paid_cents: max(group.deposit_paid_cents - cash_amount - credit_amount, 0),
        cash_paid_cents: max(group.cash_paid_cents - cash_amount, 0),
        credit_paid_cents: max(group.credit_paid_cents - credit_amount, 0)
      }

      case update_group(group, group_attrs, operation_id) do
        :ok ->
          cash_sources = cash_sources(cash_allocations)

          insert_cash_dispositions!(
            group.group_id,
            cash_sources,
            occurred_on,
            refundable?,
            refund_method,
            operation_id
          )

          if credit_issued > 0 do
            expires_on = Date.add(occurred_on, 365)

            lot =
              Repo.insert!(
                CreditLot.changeset(%CreditLot{}, %{
                  guest_id: group.guest_id,
                  source_operation_id: operation_id,
                  issued_cents: credit_issued,
                  remaining_cents: credit_issued,
                  expires_on: expires_on,
                  unrecovered_clawback_cents: 0
                })
              )

            insert_credit_entitlements!(lot.id, cash_sources)
          end

          Enum.each(credit_allocations, fn allocation ->
            if refundable?, do: restore_credit_allocation!(allocation, occurred_on)
            Repo.delete!(allocation)
          end)

          Enum.each(rooms, fn room ->
            Repo.update!(Ecto.Changeset.change(room, status: "cancelled", deposit_due_cents: 0))
          end)

          Enum.each(rooms, fn room ->
            Repo.delete_all(
              from allocation in GroupCashAllocation, where: allocation.room_id == ^room.id
            )
          end)

          {:ok,
           %{
             refunded_cents: cash_refunded,
             retained_cents: cash_retained,
             credit_issued_cents: credit_issued
           }}

        {:error, result} ->
          {:error, result}
      end
    end
  end

  defp apply_hotel_credit(operation, operation_id) do
    with {:ok, group_id} <- operation_group_id(operation) do
      unwrap_operation_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            {:error, rejection(operation_id, "group_not_found", %{group_id: group_id})}

          group ->
            with :ok <- check_revision(operation, group, operation_id),
                 :ok <- active_group(group, operation_id),
                 {:ok, amount} <- payment_amount(operation),
                 {:ok, occurred_on} <- operation_date(operation) do
              outstanding = group.deposit_due_cents - group.deposit_paid_cents

              cond do
                amount > outstanding ->
                  {:error,
                   rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group_id})}

                true ->
                  lots = available_credit_lots(group.guest_id, occurred_on)
                  available = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

                  if available < amount do
                    {:error,
                     rejection(operation_id, "insufficient_credit", %{group_id: group_id})}
                  else
                    case update_group(
                           group,
                           %{
                             deposit_paid_cents: group.deposit_paid_cents + amount,
                             credit_paid_cents: group.credit_paid_cents + amount
                           },
                           operation_id
                         ) do
                      :ok ->
                        consume_credit_lots!(lots, group, amount)

                        {:ok,
                         applied(operation_id, %{
                           group_id: group_id,
                           amount_cents: amount,
                           outstanding_deposit_cents: outstanding - amount,
                           revision: group.revision + 1
                         })}

                      {:error, result} ->
                        {:error, result}
                    end
                  end
              end
            else
              {:error, result} when is_map(result) -> {:error, result}
              {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
            end
        end
      end)
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp reduce_cash_payment(operation, operation_id) do
    with {:ok, payment_id} <- target_operation_id(operation, "payment_operation_id") do
      case Repo.get_by(PartnerOperation, operation_id: payment_id) do
        nil ->
          rejection(operation_id, "operation_not_found")

        %PartnerOperation{
          operation_type: "record_cash_payment",
          result: %{"status" => "applied"} = result
        } ->
          group_id = result["group_id"]

          unwrap_operation_result(fn ->
            case Repo.get(Group, group_id) do
              nil ->
                {:error, rejection(operation_id, "payment_not_reducible", %{group_id: group_id})}

              group ->
                with :ok <- check_revision(operation, group, operation_id),
                     {:ok, occurred_on} <- accounting_date(operation, group),
                     {:ok, amount} <- payment_amount(operation) do
                  held = cash_held_for_payment(payment_id)

                  cond do
                    held == 0 ->
                      {:error,
                       rejection(operation_id, "payment_not_reducible", %{group_id: group_id})}

                    amount > held ->
                      {:error,
                       rejection(operation_id, "reduction_exceeds_held_cash", %{
                         group_id: group_id
                       })}

                    true ->
                      removal_plan = payment_hold_removal_plan(payment_id, amount)
                      removed_by_group = removal_totals(removal_plan)

                      case update_groups_after_cash_removal!(
                             group,
                             removed_by_group,
                             operation_id
                           ) do
                        :ok ->
                          apply_payment_hold_removal!(removal_plan)

                          insert_ledger_entry!(
                            group_id,
                            "cash_reduced",
                            amount,
                            occurred_on,
                            payment_id
                          )

                          {:ok,
                           applied(operation_id, %{
                             payment_operation_id: payment_id,
                             group_id: group_id,
                             amount_cents: amount,
                             outstanding_deposit_cents:
                               max(
                                 group.deposit_due_cents - group.deposit_paid_cents +
                                   Map.get(removed_by_group, group_id, 0),
                                 0
                               ),
                             revision: group.revision + 1
                           })}

                        {:error, result} ->
                          {:error, result}
                      end
                  end
                else
                  {:error, result} when is_map(result) -> {:error, result}
                  {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
                end
            end
          end)

        %PartnerOperation{} ->
          rejection(operation_id, "payment_not_reducible")
      end
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp charge_back_payment(operation, operation_id) do
    with {:ok, payment_id} <- target_operation_id(operation, "payment_operation_id") do
      case Repo.get_by(PartnerOperation, operation_id: payment_id) do
        nil ->
          rejection(operation_id, "operation_not_found")

        %PartnerOperation{
          operation_type: "record_cash_payment",
          result: %{"status" => "applied"} = result
        } ->
          group_id = result["group_id"]

          unwrap_operation_result(fn ->
            case Repo.get(Group, group_id) do
              nil ->
                {:error, rejection(operation_id, "payment_not_chargeable", %{group_id: group_id})}

              group ->
                with :ok <- check_revision(operation, group, operation_id),
                     {:ok, occurred_on} <- accounting_date(operation, group) do
                  categories = payment_dispositions(payment_id)
                  recorded = result["amount_cents"]
                  reduced = Map.get(categories, "cash_reduced", 0)
                  already_charged = Map.get(categories, "cash_charged_back", 0)

                  cond do
                    already_charged > 0 or reduced >= recorded ->
                      {:error,
                       rejection(operation_id, "payment_not_chargeable", %{group_id: group_id})}

                    true ->
                      held = cash_held_for_payment(payment_id)
                      refunded = Map.get(categories, "cash_refunded", 0)
                      retained = Map.get(categories, "cash_retained", 0)
                      converted = Map.get(categories, "cash_converted_to_credit", 0)
                      charged_back = recorded - reduced
                      removal_plan = payment_hold_removal_plan(payment_id, held)
                      removed_by_group = removal_totals(removal_plan)

                      case update_groups_after_cash_removal!(
                             group,
                             removed_by_group,
                             operation_id
                           ) do
                        :ok ->
                          apply_payment_hold_removal!(removal_plan)

                          if refunded != 0,
                            do:
                              insert_ledger_entry!(
                                group_id,
                                "cash_refunded",
                                -refunded,
                                occurred_on,
                                payment_id
                              )

                          if retained != 0,
                            do:
                              insert_ledger_entry!(
                                group_id,
                                "cash_retained",
                                -retained,
                                occurred_on,
                                payment_id
                              )

                          if converted != 0,
                            do:
                              insert_ledger_entry!(
                                group_id,
                                "cash_converted_to_credit",
                                -converted,
                                occurred_on,
                                payment_id
                              )

                          insert_ledger_entry!(
                            group_id,
                            "cash_charged_back",
                            charged_back,
                            occurred_on,
                            payment_id
                          )

                          revoke_payment_credit!(payment_id)

                          {:ok,
                           applied(operation_id, %{
                             payment_operation_id: payment_id,
                             group_id: group_id,
                             charged_back_cents: charged_back,
                             outstanding_deposit_cents:
                               max(
                                 group.deposit_due_cents - group.deposit_paid_cents +
                                   Map.get(removed_by_group, group_id, 0),
                                 0
                               ),
                             revision: group.revision + 1
                           })}

                        {:error, result} ->
                          {:error, result}
                      end
                  end
                else
                  {:error, result} when is_map(result) -> {:error, result}
                  {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
                end
            end
          end)

        %PartnerOperation{} ->
          rejection(operation_id, "payment_not_chargeable")
      end
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp transfer_deposit(operation, operation_id) do
    with {:ok, source_group_id} <- target_operation_id(operation, "source_group_id"),
         {:ok, destination_group_id} <- target_operation_id(operation, "destination_group_id") do
      unwrap_operation_result(fn ->
        case Repo.get(Group, source_group_id) do
          nil ->
            {:error, rejection(operation_id, "group_not_found", %{group_id: source_group_id})}

          source ->
            case Repo.get(Group, destination_group_id) do
              nil ->
                {:error,
                 rejection(operation_id, "group_not_found", %{group_id: destination_group_id})}

              destination ->
                with :ok <- check_revision(operation, source, operation_id),
                     :ok <-
                       check_revision(
                         operation,
                         "destination_expected_revision",
                         destination,
                         operation_id
                       ) do
                  cond do
                    source.group_id == destination.group_id or
                        source.guest_id != destination.guest_id ->
                      {:error, rejection(operation_id, "invalid_transfer")}

                    source.status != "active" ->
                      {:error,
                       rejection(operation_id, "group_not_active", %{group_id: source.group_id})}

                    destination.status != "active" ->
                      {:error,
                       rejection(operation_id, "group_not_active", %{
                         group_id: destination.group_id
                       })}

                    true ->
                      case payment_amount(operation) do
                        {:error, code} ->
                          {:error, rejection(operation_id, code)}

                        {:ok, amount} ->
                          source_held = group_held_funding(source.group_id)
                          destination_outstanding = group_outstanding(destination)

                          cond do
                            amount > source_held ->
                              {:error, rejection(operation_id, "transfer_exceeds_held_funding")}

                            amount > destination_outstanding ->
                              {:error, rejection(operation_id, "transfer_exceeds_outstanding")}

                            true ->
                              chunks = transfer_chunks(source.group_id, amount)
                              cash_amount = sum_chunk_amount(chunks, :cash)
                              credit_amount = sum_chunk_amount(chunks, :credit)

                              source_attrs = %{
                                deposit_paid_cents: source.deposit_paid_cents - amount,
                                cash_paid_cents: source.cash_paid_cents - cash_amount,
                                credit_paid_cents: source.credit_paid_cents - credit_amount
                              }

                              destination_attrs = %{
                                deposit_paid_cents: destination.deposit_paid_cents + amount,
                                cash_paid_cents: destination.cash_paid_cents + cash_amount,
                                credit_paid_cents: destination.credit_paid_cents + credit_amount
                              }

                              with :ok <- update_group(source, source_attrs, operation_id),
                                   :ok <-
                                     update_group(destination, destination_attrs, operation_id) do
                                move_transfer_allocations!(chunks, destination)

                                {:ok,
                                 applied(operation_id, %{
                                   source_group_id: source.group_id,
                                   destination_group_id: destination.group_id,
                                   amount_cents: amount,
                                   source_outstanding_deposit_cents:
                                     group_outstanding(source) + amount,
                                   destination_outstanding_deposit_cents:
                                     destination_outstanding - amount,
                                   source_revision: source.revision + 1,
                                   destination_revision: destination.revision + 1
                                 })}
                              else
                                {:error, result} -> {:error, result}
                              end
                          end
                      end
                  end
                else
                  {:error, result} -> {:error, result}
                end
            end
        end
      end)
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp open_attributes(operation) do
    with {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on} <- date_field(operation, "arrival_on"),
         {:ok, departure_on} <- date_field(operation, "departure_on"),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         guest_id when is_binary(guest_id) and byte_size(guest_id) > 0 <-
           Map.get(operation, "guest_id"),
         property_id when is_binary(property_id) and byte_size(property_id) > 0 <-
           Map.get(operation, "property_id"),
         {:ok, rate_plan} <- rate_plan(Map.get(operation, "rate_plan")),
         {:ok, rooms, lodging_total, deposit_due} <-
           room_amounts(Map.get(operation, "rooms"), arrival_on, departure_on, rate_plan) do
      group_id = Map.get(operation, "group_id")

      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
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
       }, rooms}
    else
      false -> {:error, "invalid_stay"}
      {:error, code} -> {:error, code}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp room_amounts(rooms, arrival_on, departure_on, rate_plan)
       when is_list(rooms) and rooms != [] do
    nights = Date.diff(departure_on, arrival_on)

    parsed =
      Enum.reduce_while(rooms, {:ok, [], MapSet.new(), 0, 0}, fn room,
                                                                 {:ok, attrs, seen, lodging_sum,
                                                                  deposit_sum} ->
        room_id = if is_map(room), do: Map.get(room, "room_id"), else: nil
        nightly_rate = if is_map(room), do: Map.get(room, "nightly_rate_cents"), else: nil

        cond do
          not valid_identifier?(room_id) ->
            {:halt, {:error, "invalid_rooms"}}

          MapSet.member?(seen, room_id) ->
            {:halt, {:error, "invalid_rooms"}}

          not is_integer(nightly_rate) or nightly_rate <= 0 or nightly_rate > @max_integer ->
            {:halt, {:error, "invalid_rooms"}}

          true ->
            lodging = nights * nightly_rate
            deposit = room_deposit(rate_plan, lodging)

            if lodging > @max_integer or lodging_sum + lodging > @max_integer or
                 deposit_sum + deposit > @max_integer do
              {:halt, {:error, "invalid_rooms"}}
            else
              room_attrs = %{
                group_id: nil,
                room_id: room_id,
                nightly_rate_cents: nightly_rate,
                position: length(attrs),
                status: "active",
                deposit_due_cents: deposit
              }

              {:cont,
               {:ok, [room_attrs | attrs], MapSet.put(seen, room_id), lodging_sum + lodging,
                deposit_sum + deposit}}
            end
        end
      end)

    case parsed do
      {:ok, attrs, _seen, lodging_total, deposit_due} ->
        {:ok, Enum.reverse(attrs), lodging_total, deposit_due}

      error ->
        error
    end
  end

  defp room_amounts(_, _arrival_on, _departure_on, _rate_plan), do: {:error, "invalid_rooms"}

  defp room_deposit("flexible", lodging), do: div(lodging * 20 + 50, 100)
  defp room_deposit("advance_purchase", lodging), do: lodging

  defp operation_group_id(operation) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 -> {:ok, group_id}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp target_operation_id(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp rate_plan(value) when value in ["flexible", "advance_purchase"], do: {:ok, value}
  defp rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp operation_date(operation) do
    case Map.fetch(operation, "occurred_on") do
      :error -> {:error, "invalid_operation"}
      {:ok, value} -> parse_date(value, "invalid_stay")
    end
  end

  defp accounting_date(operation, group) do
    case Map.fetch(operation, "occurred_on") do
      :error -> {:ok, group.booked_on}
      {:ok, value} -> parse_date(value, "invalid_stay")
    end
  end

  defp date_field(operation, key) do
    case Map.fetch(operation, key) do
      :error -> {:error, "invalid_stay"}
      {:ok, value} -> parse_date(value, "invalid_stay")
    end
  end

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, code}
    end
  end

  defp parse_date(_, code), do: {:error, code}

  defp shifted_date(date, day_shift) do
    {:ok, Date.add(date, day_shift)}
  rescue
    _ -> :error
  end

  defp payment_amount(operation) do
    case Map.get(operation, "amount_cents") do
      amount when is_integer(amount) and amount > 0 and amount <= @max_integer -> {:ok, amount}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp check_revision(operation, group, operation_id) do
    check_revision(operation, "expected_revision", group, operation_id)
  end

  defp check_revision(operation, revision_key, group, operation_id) do
    case Map.fetch(operation, revision_key) do
      :error ->
        :ok

      {:ok, expected} when expected === group.revision ->
        :ok

      {:ok, expected} ->
        {:error,
         rejection(operation_id, "stale_revision", %{
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         })}
    end
  end

  defp active_group(%Group{status: "active"}, _operation_id), do: :ok

  defp active_group(group, operation_id),
    do: {:error, rejection(operation_id, "group_not_active", %{group_id: group.group_id})}

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on),
    do: if(Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30")

  defp refundable_until(%Group{policy_version: version, arrival_on: arrival_on}),
    do: refundable_until_for(version, arrival_on)

  defp refundable_until_for("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until_for("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until_for("advance-nonrefundable", _arrival_on), do: nil
  defp date_json(nil), do: nil
  defp date_json(%Date{} = date), do: Date.to_iso8601(date)

  defp refundable_on?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> {:ok, "cash"}
      {:ok, method} when method in ["cash", "hotel_credit"] -> {:ok, method}
      {:ok, _} -> {:error, "invalid_refund_method"}
    end
  end

  defp refund_method_allowed("hotel_credit", false, operation_id, group_id),
    do: {:error, rejection(operation_id, "refund_method_not_available", %{group_id: group_id})}

  defp refund_method_allowed(_method, _refundable?, _operation_id, _group_id), do: :ok
  defp credit_issue_amount(cash_cents), do: cash_cents + div(cash_cents + 5, 10)

  defp available_credit_lots(guest_id, on_date) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on_date,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: room.position
    )
  end

  defp selected_active_rooms(operation, group_id) do
    case Map.get(operation, "room_ids") do
      ids when is_list(ids) and ids != [] ->
        valid_ids? =
          Enum.all?(ids, &valid_identifier?/1) and length(Enum.uniq(ids)) == length(ids)

        rooms = active_rooms(group_id)
        requested = MapSet.new(ids)
        selected = Enum.filter(rooms, &MapSet.member?(requested, &1.room_id))

        if valid_ids? and length(selected) == length(ids),
          do: {:ok, selected},
          else: {:error, "invalid_rooms"}

      _ ->
        {:error, "invalid_rooms"}
    end
  end

  defp room_lodging(group, room),
    do: Date.diff(group.departure_on, group.arrival_on) * room.nightly_rate_cents

  defp cash_allocations_for_rooms(_group_id, []), do: []

  defp cash_allocations_for_rooms(group_id, room_ids) do
    Repo.all(
      from allocation in GroupCashAllocation,
        where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids,
        order_by: allocation.allocation_order
    )
  end

  defp credit_allocations_for_rooms(_group_id, []), do: []

  defp credit_allocations_for_rooms(group_id, room_ids) do
    Repo.all(
      from allocation in GroupCreditAllocation,
        where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids,
        order_by: allocation.allocation_order
    )
  end

  defp group_outstanding(group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp group_held_funding(group_id) do
    cash =
      Repo.one(
        from allocation in GroupCashAllocation,
          where: allocation.group_id == ^group_id,
          select: sum(allocation.amount_cents)
      ) || 0

    credit =
      Repo.one(
        from allocation in GroupCreditAllocation,
          where: allocation.group_id == ^group_id,
          select: sum(allocation.amount_cents)
      ) || 0

    cash + credit
  end

  defp transfer_chunks(group_id, amount) do
    cash_chunks =
      Repo.all(
        from allocation in GroupCashAllocation,
          where: allocation.group_id == ^group_id,
          order_by: [desc: allocation.allocation_order]
      )
      |> Enum.map(fn allocation ->
        %{kind: :cash, allocation: allocation, allocation_order: allocation.allocation_order}
      end)

    credit_chunks =
      Repo.all(
        from allocation in GroupCreditAllocation,
          where: allocation.group_id == ^group_id,
          order_by: [desc: allocation.allocation_order]
      )
      |> Enum.map(fn allocation ->
        %{kind: :credit, allocation: allocation, allocation_order: allocation.allocation_order}
      end)

    {chunks, remaining} =
      Enum.reduce_while(
        Enum.sort_by(cash_chunks ++ credit_chunks, & &1.allocation_order, :desc),
        {[], amount},
        fn chunk, {chunks, left} ->
          used = min(chunk.allocation.amount_cents, left)

          next_chunks =
            if used > 0, do: [Map.put(chunk, :amount_cents, used) | chunks], else: chunks

          if used == left,
            do: {:halt, {next_chunks, 0}},
            else: {:cont, {next_chunks, left - used}}
        end
      )

    if remaining != 0, do: raise("group held-funding allocation is inconsistent")
    Enum.reverse(chunks)
  end

  defp sum_chunk_amount(chunks, kind) do
    Enum.reduce(chunks, 0, fn chunk, total ->
      if chunk.kind == kind, do: total + chunk.amount_cents, else: total
    end)
  end

  defp move_transfer_allocations!(chunks, destination) do
    Enum.each(chunks, fn chunk ->
      allocation = chunk.allocation
      remaining = allocation.amount_cents - chunk.amount_cents

      if remaining == 0 do
        Repo.delete!(allocation)
      else
        Repo.update!(Ecto.Changeset.change(allocation, amount_cents: remaining))
      end
    end)

    room_needs =
      active_rooms(destination.group_id)
      |> Enum.map(fn room -> {room.id, room_capacity(room)} end)
      |> Enum.reject(fn {_room_id, capacity} -> capacity == 0 end)

    {destination_allocations, _remaining_needs} =
      Enum.reduce(chunks, {[], room_needs}, fn chunk, {allocations, needs} ->
        {new_allocations, new_needs} = spread_transfer_chunk(needs, chunk, [])
        {allocations ++ new_allocations, new_needs}
      end)

    Enum.each(destination_allocations, fn allocation ->
      allocation_order = next_funding_allocation_order!()

      case allocation.kind do
        :cash ->
          Repo.insert!(
            GroupCashAllocation.changeset(%GroupCashAllocation{}, %{
              group_id: destination.group_id,
              room_id: allocation.room_id,
              payment_operation_id: allocation.payment_operation_id,
              amount_cents: allocation.amount_cents,
              allocation_order: allocation_order
            })
          )

        :credit ->
          Repo.insert!(
            GroupCreditAllocation.changeset(%GroupCreditAllocation{}, %{
              group_id: destination.group_id,
              room_id: allocation.room_id,
              credit_lot_id: allocation.credit_lot_id,
              amount_cents: allocation.amount_cents,
              allocation_order: allocation_order
            })
          )
      end
    end)

    payment_ids =
      chunks
      |> Enum.filter(&(&1.kind == :cash))
      |> Enum.map(& &1.allocation.payment_operation_id)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if payment_ids != [] do
      Repo.update_all(
        from(operation in PartnerOperation, where: operation.operation_id in ^payment_ids),
        set: [transferred_funding: true]
      )
    end
  end

  defp spread_transfer_chunk(needs, chunk, allocations) do
    spread_transfer_chunk(needs, chunk.amount_cents, chunk, allocations)
  end

  defp spread_transfer_chunk(needs, 0, _chunk, allocations),
    do: {Enum.reverse(allocations), needs}

  defp spread_transfer_chunk([], _amount, _chunk, _allocations),
    do: raise("destination room capacity did not cover transfer")

  defp spread_transfer_chunk([{room_id, capacity} | rest], amount, chunk, allocations) do
    used = min(capacity, amount)

    next_allocations =
      if used > 0 do
        provenance =
          case chunk.kind do
            :cash -> %{payment_operation_id: chunk.allocation.payment_operation_id}
            :credit -> %{credit_lot_id: chunk.allocation.credit_lot_id}
          end

        [
          Map.merge(
            %{kind: chunk.kind, room_id: room_id, amount_cents: used},
            provenance
          )
          | allocations
        ]
      else
        allocations
      end

    next_needs = if capacity > used, do: [{room_id, capacity - used} | rest], else: rest
    spread_transfer_chunk(next_needs, amount - used, chunk, next_allocations)
  end

  defp next_funding_allocation_order! do
    cash_order =
      Repo.one(from allocation in GroupCashAllocation, select: max(allocation.allocation_order)) ||
        0

    credit_order =
      Repo.one(from allocation in GroupCreditAllocation, select: max(allocation.allocation_order)) ||
        0

    max(cash_order, credit_order) + 1
  end

  defp cash_sources(allocations) do
    {order, totals} =
      Enum.reduce(allocations, {[], %{}}, fn allocation, {order, totals} ->
        key = allocation.payment_operation_id

        if Map.has_key?(totals, key) do
          {order, Map.update!(totals, key, &(&1 + allocation.amount_cents))}
        else
          {order ++ [key], Map.put(totals, key, allocation.amount_cents)}
        end
      end)

    Enum.map(order, &{&1, Map.fetch!(totals, &1)})
  end

  defp insert_cash_dispositions!(
         _group_id,
         [],
         _occurred_on,
         _refundable?,
         _refund_method,
         _operation_id
       ),
       do: :ok

  defp insert_cash_dispositions!(
         group_id,
         sources,
         occurred_on,
         refundable?,
         refund_method,
         _operation_id
       ) do
    type =
      cond do
        refundable? and refund_method == "cash" -> "cash_refunded"
        refundable? and refund_method == "hotel_credit" -> "cash_converted_to_credit"
        true -> "cash_retained"
      end

    Enum.each(sources, fn {payment_id, amount} ->
      insert_ledger_entry!(group_id, type, amount, occurred_on, payment_id)
    end)
  end

  defp insert_credit_entitlements!(_lot_id, []), do: :ok

  defp insert_credit_entitlements!(lot_id, sources) do
    Enum.reduce(sources, {0, 0}, fn {payment_id, principal},
                                    {running_principal, previous_bonus} ->
      next_principal = running_principal + principal
      next_bonus = div(next_principal + 5, 10)
      entitlement = principal + next_bonus - previous_bonus

      if is_binary(payment_id) and entitlement > 0 do
        Repo.insert!(
          PaymentCreditEntitlement.changeset(%PaymentCreditEntitlement{}, %{
            credit_lot_id: lot_id,
            payment_operation_id: payment_id,
            amount_cents: entitlement
          })
        )
      end

      {next_principal, next_bonus}
    end)
  end

  defp restore_credit_allocation!(allocation, occurred_on) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)
    available = allocation.amount_cents - absorbed
    keep_available? = Date.compare(lot.expires_on, occurred_on) != :lt

    Repo.update!(
      Ecto.Changeset.change(lot,
        remaining_cents: lot.remaining_cents + if(keep_available?, do: available, else: 0),
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      )
    )
  end

  defp allocate_cash_to_rooms!(group, amount, payment_operation_id) do
    rooms = active_rooms(group.group_id)

    {allocations, remaining} =
      Enum.reduce_while(rooms, {[], amount}, fn room, {allocations, left} ->
        capacity = room_capacity(room)
        used = min(capacity, left)

        next =
          if used > 0,
            do: [%{room_id: room.id, amount_cents: used} | allocations],
            else: allocations

        if left == used, do: {:halt, {next, 0}}, else: {:cont, {next, left - used}}
      end)

    if remaining != 0, do: raise("room deposit allocation did not cover cash payment")

    allocations
    |> Enum.reverse()
    |> Enum.each(fn allocation ->
      Repo.insert!(
        GroupCashAllocation.changeset(%GroupCashAllocation{}, %{
          group_id: group.group_id,
          room_id: allocation.room_id,
          payment_operation_id: payment_operation_id,
          amount_cents: allocation.amount_cents,
          allocation_order: next_funding_allocation_order!()
        })
      )
    end)
  end

  defp room_capacity(room) do
    cash =
      Repo.one(
        from allocation in GroupCashAllocation,
          where: allocation.room_id == ^room.id,
          select: sum(allocation.amount_cents)
      ) || 0

    credit =
      Repo.one(
        from allocation in GroupCreditAllocation,
          where: allocation.room_id == ^room.id,
          select: sum(allocation.amount_cents)
      ) || 0

    max(room.deposit_due_cents - cash - credit, 0)
  end

  defp consume_credit_lots!(lots, group, amount) do
    room_needs =
      active_rooms(group.group_id)
      |> Enum.map(fn room -> {room.id, room_capacity(room)} end)
      |> Enum.reject(fn {_room_id, need} -> need == 0 end)

    {allocations, room_needs, remaining} =
      Enum.reduce_while(lots, {[], room_needs, amount}, fn lot, {allocations, needs, left} ->
        used = min(lot.remaining_cents, left)
        {new_allocations, new_needs} = spread_lot_across_rooms(needs, lot.id, used, [])
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - used))
        next_allocations = allocations ++ new_allocations

        if left == used,
          do: {:halt, {next_allocations, new_needs, 0}},
          else: {:cont, {next_allocations, new_needs, left - used}}
      end)

    if remaining != 0, do: raise("credit lots did not cover hotel-credit application")

    Enum.each(allocations, fn allocation ->
      Repo.insert!(
        GroupCreditAllocation.changeset(%GroupCreditAllocation{}, %{
          group_id: group.group_id,
          room_id: allocation.room_id,
          credit_lot_id: allocation.credit_lot_id,
          amount_cents: allocation.amount_cents,
          allocation_order: next_funding_allocation_order!()
        })
      )
    end)

    room_needs
  end

  defp spread_lot_across_rooms(needs, _lot_id, 0, allocations),
    do: {Enum.reverse(allocations), needs}

  defp spread_lot_across_rooms([], _lot_id, _amount, allocations),
    do: {Enum.reverse(allocations), []}

  defp spread_lot_across_rooms([{room_id, need} | rest], lot_id, amount, allocations) do
    used = min(need, amount)

    next_allocations =
      if used > 0,
        do: [%{room_id: room_id, credit_lot_id: lot_id, amount_cents: used} | allocations],
        else: allocations

    next_needs = if need > used, do: [{room_id, need - used} | rest], else: rest
    spread_lot_across_rooms(next_needs, lot_id, amount - used, next_allocations)
  end

  defp payment_dispositions(payment_operation_id) do
    Repo.all(
      from entry in LedgerEntry,
        where: entry.payment_operation_id == ^payment_operation_id,
        group_by: entry.entry_type,
        select: {entry.entry_type, sum(entry.amount_cents)}
    )
    |> Map.new(fn {type, amount} -> {type, amount || 0} end)
  end

  defp cash_held_for_payment(payment_id) do
    Repo.one(
      from allocation in GroupCashAllocation,
        where: allocation.payment_operation_id == ^payment_id,
        select: sum(allocation.amount_cents)
    ) || 0
  end

  defp payment_hold_removal_plan(_payment_id, 0), do: []

  defp payment_hold_removal_plan(payment_id, amount) do
    allocations =
      Repo.all(
        from allocation in GroupCashAllocation,
          where: allocation.payment_operation_id == ^payment_id,
          order_by: [desc: allocation.allocation_order]
      )

    {remaining, plan} =
      Enum.reduce_while(allocations, {amount, []}, fn allocation, {left, plan} ->
        used = min(left, allocation.amount_cents)
        next_plan = if used > 0, do: [{allocation, used} | plan], else: plan
        if used == left, do: {:halt, {0, next_plan}}, else: {:cont, {left - used, next_plan}}
      end)

    if remaining != 0, do: raise("payment hold allocation is inconsistent")
    Enum.reverse(plan)
  end

  defp removal_totals(plan) do
    Enum.reduce(plan, %{}, fn {allocation, amount}, totals ->
      Map.update(totals, allocation.group_id, amount, &(&1 + amount))
    end)
  end

  defp apply_payment_hold_removal!(plan) do
    Enum.each(plan, fn {allocation, amount} ->
      remaining = allocation.amount_cents - amount

      if remaining == 0 do
        Repo.delete!(allocation)
      else
        Repo.update!(Ecto.Changeset.change(allocation, amount_cents: remaining))
      end
    end)
  end

  defp update_groups_after_cash_removal!(addressed_group, removed_by_group, operation_id) do
    group_ids =
      removed_by_group
      |> Map.keys()
      |> Kernel.++([addressed_group.group_id])
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce_while(group_ids, :ok, fn group_id, :ok ->
      group =
        if group_id == addressed_group.group_id,
          do: addressed_group,
          else: Repo.get(Group, group_id)

      if is_nil(group) do
        {:halt, {:error, rejection(operation_id, "group_not_found", %{group_id: group_id})}}
      else
        amount = Map.get(removed_by_group, group_id, 0)

        attrs = %{
          deposit_paid_cents: max(group.deposit_paid_cents - amount, 0),
          cash_paid_cents: max(group.cash_paid_cents - amount, 0)
        }

        case update_group(group, attrs, operation_id) do
          :ok -> {:cont, :ok}
          {:error, result} -> {:halt, {:error, result}}
        end
      end
    end)
  end

  defp revoke_payment_credit!(payment_id) do
    entitlements =
      Repo.all(
        from entitlement in PaymentCreditEntitlement,
          where: entitlement.payment_operation_id == ^payment_id
      )

    Enum.each(entitlements, fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)
      unrecovered = entitlement.amount_cents - removed

      Repo.update!(
        Ecto.Changeset.change(lot,
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
        )
      )
    end)
  end

  defp update_group(group, attrs, operation_id) do
    query =
      from current in Group,
        where: current.group_id == ^group.group_id and current.revision == ^group.revision

    {count, _} = Repo.update_all(query, set: Map.to_list(attrs), inc: [revision: 1])

    if count == 1 do
      :ok
    else
      actual = Repo.get(Group, group.group_id)

      if actual do
        {:error,
         rejection(operation_id, "stale_revision", %{
           group_id: group.group_id,
           expected_revision: group.revision,
           actual_revision: actual.revision
         })}
      else
        {:error, rejection(operation_id, "group_not_found", %{group_id: group.group_id})}
      end
    end
  end

  defp insert_ledger_entry!(group_id, type, amount, occurred_on, payment_operation_id) do
    Repo.insert!(
      LedgerEntry.changeset(%LedgerEntry{}, %{
        group_id: group_id,
        payment_operation_id: payment_operation_id,
        entry_type: type,
        amount_cents: amount,
        occurred_on: occurred_on
      })
    )
  end

  defp unwrap_operation_result(fun) do
    case fun.() do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp rejection(operation_id, code, fields \\ %{}),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0
end
