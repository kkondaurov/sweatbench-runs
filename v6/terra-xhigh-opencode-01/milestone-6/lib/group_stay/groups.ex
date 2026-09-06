defmodule GroupStay.Groups do
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias GroupStay.Groups.CashPaymentSource
  alias GroupStay.Groups.CashPaymentDisposition
  alias GroupStay.Groups.CashRoomAllocation
  alias GroupStay.Groups.CreditAllocation
  alias GroupStay.Groups.FinanceCashMovement
  alias GroupStay.Groups.FinanceCashOpening
  alias GroupStay.Groups.FinanceCreditAvailabilityMovement
  alias GroupStay.Groups.FinanceCreditLotOpening
  alias GroupStay.Groups.FinanceCreditMovement
  alias GroupStay.Groups.FinanceReporting
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.HotelCreditLot
  alias GroupStay.Groups.PartnerOperation
  alias GroupStay.Groups.PaymentCreditEntitlement
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]
  @cash_movement_types [
    "received",
    "transferred_in",
    "transferred_out",
    "refunded",
    "retained",
    "converted_to_credit",
    "reduced",
    "charged_back"
  ]
  @credit_movement_types ["issued", "expired", "consumed", "revoked", "absorbed"]

  def apply_operation(operation) when is_map(operation) do
    if valid_identifier?(operation["operation_id"]) do
      apply_and_remember_operation(operation)
    else
      apply_new_operation(operation)
    end
  end

  def apply_operation(_), do: rejected(%{}, "invalid_operation")

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_operation(_operation_id), do: nil

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> serialize_group(group)
    end
  end

  def get_group(_group_id), do: nil

  def ledger(on \\ Date.utc_today()) do
    %{
      cash_held_cents: held_cash_total(),
      cash_refunded_cents: source_total(:refunded_cents),
      cash_retained_cents: source_total(:retained_cents),
      cash_converted_to_credit_cents: source_total(:converted_to_credit_cents),
      cash_reduced_cents: source_total(:reduced_cents),
      cash_charged_back_cents: source_total(:charged_back_cents),
      credit_liability_cents: available_credit_total(on) + applied_credit_total(),
      credit_shortfall_cents: credit_shortfall_total()
    }
  end

  def daily_finance_report(%Date{} = date) do
    case reporting() do
      %FinanceReporting{starts_on: starts_on} = finance_reporting ->
        if Date.compare(date, starts_on) == :lt do
          :not_available
        else
          {:ok,
           %{
             date: date_string(date),
             status: "open",
             cash: daily_cash_report(finance_reporting, date),
             credit: daily_credit_report(finance_reporting, date)
           }}
        end

      nil ->
        :not_available
    end
  end

  def guest_credit(guest_id, on \\ Date.utc_today())

  def guest_credit(guest_id, on) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: date_string(lot.expires_on)
          }
        end)
    }
  end

  def guest_credit(_guest_id, _on), do: nil

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    {:ok, payment} = Repo.transaction(fn -> payment_statement(payment_operation_id) end)
    payment
  end

  def get_payment(_payment_operation_id), do: {:error, :operation_not_found}

  # The statement's source dispositions and held allocations must come from one database snapshot.
  defp payment_statement(payment_operation_id) do
    with %PartnerOperation{} = operation <-
           Repo.get_by(PartnerOperation, operation_id: payment_operation_id),
         true <- applied_cash_payment?(operation),
         %CashPaymentSource{} = source <-
           Repo.get_by(CashPaymentSource, payment_operation_id: payment_operation_id),
         %Group{} = group <- Repo.get(Group, source.group_id) do
      statement = %{
        payment_operation_id: payment_operation_id,
        original_group_id: group.group_id,
        recorded_cents: source.recorded_cents,
        held_cents: held_cash_for_source(source.id),
        refunded_cents: source.refunded_cents,
        retained_cents: source.retained_cents,
        converted_to_credit_cents: source.converted_to_credit_cents,
        reduced_cents: source.reduced_cents,
        charged_back_cents: source.charged_back_cents
      }

      {:ok,
       if source.participated_in_transfer do
         Map.put(statement, :held_by_group, held_cash_by_group(source.id))
       else
         statement
       end}
    else
      nil -> {:error, :operation_not_found}
      false -> {:error, :payment_not_reconcilable}
    end
  end

  defp apply_and_remember_operation(operation) do
    # Acquire SQLite's writer lock before checking the record so concurrent retries serialize.
    case Repo.transaction(
           fn ->
             case Repo.get_by(PartnerOperation, operation_id: operation["operation_id"]) do
               nil ->
                 case apply_new_operation(operation) do
                   :retry ->
                     Repo.rollback(:retry)

                   result ->
                     case Repo.insert_all(
                            PartnerOperation,
                            [
                              %{
                                operation_id: operation["operation_id"],
                                operation_type: operation_type(operation),
                                payload: operation,
                                result: result
                              }
                            ],
                            on_conflict: :nothing,
                            conflict_target: [:operation_id]
                          ) do
                       {1, _} -> result
                       {0, _} -> Repo.rollback(:operation_id_race)
                     end
                 end

               remembered_operation ->
                 if equivalent_json?(remembered_operation.payload, operation) do
                   remembered_operation.result
                 else
                   rejected(operation, "operation_id_conflict")
                 end
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, :operation_id_race} -> apply_and_remember_operation(operation)
      {:error, :retry} -> apply_and_remember_operation(operation)
      {:error, reason} -> raise "could not persist partner operation: #{inspect(reason)}"
    end
  end

  defp apply_new_operation(operation) do
    case operation["type"] do
      "start_finance_reporting" -> start_finance_reporting(operation)
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "cancel_rooms" -> cancel_rooms(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      "transfer_deposit" -> transfer_deposit(operation)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp start_finance_reporting(operation) do
    with true <- valid_identifier?(operation["operation_id"]),
         {:ok, starts_on} <- parse_date(operation["starts_on"]) do
      case reporting() do
        nil ->
          finance_reporting =
            Repo.insert!(%FinanceReporting{
              reporting_key: 1,
              starts_on: starts_on,
              opening_credit_liability_cents:
                available_credit_total(starts_on) + applied_credit_total()
            })

          snapshot_finance_cash_openings(finance_reporting)
          snapshot_finance_credit_lot_openings(finance_reporting)

          applied(operation, %{starts_on: date_string(starts_on)})

        _finance_reporting ->
          rejected(operation, "reporting_already_started")
      end
    else
      false -> rejected(operation, "invalid_operation")
      _ -> rejected(operation, "invalid_reporting_date")
    end
  end

  defp open_group(operation) do
    with {:ok, booked_on} <- common_date(operation),
         {:ok, attributes, rooms} <- open_attributes(operation, booked_on) do
      if Repo.get_by(Group, group_id: attributes.group_id) do
        group_error(operation, "group_already_exists", attributes.group_id)
      else
        case Repo.insert(Group.changeset(%Group{}, attributes)) do
          {:ok, group} ->
            room_rows = Enum.map(rooms, &Map.put(&1, :group_id, group.id))
            {room_count, _} = Repo.insert_all(Room, room_rows)

            if room_count == length(room_rows) do
              applied(operation, %{
                group_id: group.group_id,
                deposit_due_cents: group.deposit_due_cents,
                revision: group.revision
              })
            else
              raise "could not create all group rooms"
            end

          {:error, changeset} ->
            if Keyword.has_key?(changeset.errors, :group_id) do
              group_error(operation, "group_already_exists", attributes.group_id)
            else
              rejected(operation, "invalid_operation")
            end
        end
      end
    else
      {:error, result} -> result
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, _occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        amount = operation["amount_cents"]
        totals = group_totals(group.id)

        cond do
          group.status != "active" ->
            {:error, group_error(operation, "group_not_active", group.group_id)}

          not positive_integer?(amount) ->
            {:error, group_error(operation, "invalid_amount", group.group_id)}

          amount > totals.deposit_due_cents - totals.deposit_paid_cents ->
            {:error, group_error(operation, "payment_exceeds_outstanding", group.group_id)}

          true ->
            room_segments = funding_room_segments(group.id, amount)

            {:update, payment_total_changes(group, totals, amount, 0),
             fn updated ->
               applied(operation, %{
                 group_id: updated.group_id,
                 amount_cents: amount,
                 outstanding_deposit_cents:
                   totals.deposit_due_cents - totals.deposit_paid_cents - amount,
                 revision: updated.revision
               })
             end,
             fn _updated ->
               source =
                 Repo.insert!(%CashPaymentSource{
                   group_id: group.id,
                   payment_operation_id: operation["operation_id"],
                   recorded_cents: amount,
                   refunded_cents: 0,
                   retained_cents: 0,
                   converted_to_credit_cents: 0,
                   reduced_cents: 0,
                   charged_back_cents: 0,
                   participated_in_transfer: false
                 })

               insert_cash_room_allocations(source.id, room_segments)
               record_cash_movement(operation, group.property_id, "received", amount)
               :ok
             end}
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp reschedule_group(operation) do
    with {:ok, occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        cond do
          group.status != "active" ->
            {:error, group_error(operation, "group_not_active", group.group_id)}

          true ->
            case parse_date(operation["new_arrival_on"]) do
              {:ok, new_arrival_on} ->
                if Date.compare(new_arrival_on, occurred_on) == :gt do
                  stay_length = Date.diff(group.departure_on, group.arrival_on)
                  new_departure_on = Date.add(new_arrival_on, stay_length)

                  {:update, [arrival_on: new_arrival_on, departure_on: new_departure_on],
                   fn updated ->
                     applied(operation, %{
                       group_id: updated.group_id,
                       new_arrival_on: date_string(updated.arrival_on),
                       new_departure_on: date_string(updated.departure_on),
                       policy_version: updated.policy_version,
                       refundable_until: date_string(refundable_until(updated)),
                       revision: updated.revision
                     })
                   end}
                else
                  {:error, group_error(operation, "invalid_stay", group.group_id)}
                end

              _ ->
                {:error, group_error(operation, "invalid_stay", group.group_id)}
            end
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp cancel_group(operation) do
    with {:ok, occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        case active_rooms(group.id) do
          [] -> {:error, group_error(operation, "group_not_active", group.group_id)}
          rooms -> cancel_selected_rooms(operation, group, occurred_on, rooms, false)
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        cond do
          group.status != "active" ->
            {:error, group_error(operation, "group_not_active", group.group_id)}

          true ->
            case selected_active_rooms(group.id, operation["room_ids"]) do
              {:ok, rooms} -> cancel_selected_rooms(operation, group, occurred_on, rooms, true)
              :error -> {:error, group_error(operation, "invalid_rooms", group.group_id)}
            end
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        amount = operation["amount_cents"]
        totals = group_totals(group.id)

        cond do
          group.status != "active" ->
            {:error, group_error(operation, "group_not_active", group.group_id)}

          not positive_integer?(amount) ->
            {:error, group_error(operation, "invalid_amount", group.group_id)}

          amount > totals.deposit_due_cents - totals.deposit_paid_cents ->
            {:error, group_error(operation, "payment_exceeds_outstanding", group.group_id)}

          true ->
            case credit_redemptions(group.guest_id, occurred_on, amount) do
              {:error, :insufficient_credit} ->
                {:error, group_error(operation, "insufficient_credit", group.group_id)}

              {:ok, redemptions} ->
                room_segments = credit_room_segments(group.id, redemptions)

                {:update, payment_total_changes(group, totals, 0, amount),
                 fn updated ->
                   applied(operation, %{
                     group_id: updated.group_id,
                     amount_cents: amount,
                     outstanding_deposit_cents:
                       totals.deposit_due_cents - totals.deposit_paid_cents - amount,
                     revision: updated.revision
                   })
                 end,
                 fn _updated ->
                   with :ok <- decrement_credit_lots(redemptions),
                        :ok <- insert_credit_room_allocations(group.id, room_segments) do
                     record_credit_availability_redemptions(operation, redemptions)
                     :ok
                   else
                     :error -> :retry
                   end
                 end}
            end
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, _occurred_on} <- common_date(operation),
         {:ok, source_group_id} <- transfer_group_id(operation, "source_group_id"),
         {:ok, destination_group_id} <- transfer_group_id(operation, "destination_group_id") do
      case Repo.get_by(Group, group_id: source_group_id) do
        nil ->
          group_error(operation, "group_not_found", source_group_id)

        source_group ->
          case Repo.get_by(Group, group_id: destination_group_id) do
            nil ->
              group_error(operation, "group_not_found", destination_group_id)

            destination_group ->
              transfer_between_groups(operation, source_group, destination_group)
          end
      end
    else
      {:error, result} -> result
    end
  end

  defp transfer_between_groups(operation, source_group, destination_group) do
    cond do
      stale_revision?(operation, source_group) ->
        stale_revision_error(operation, source_group)

      destination_stale_revision?(operation, destination_group) ->
        destination_stale_revision_error(operation, destination_group)

      source_group.id == destination_group.id or
          source_group.guest_id != destination_group.guest_id ->
        rejected(operation, "invalid_transfer")

      source_group.status != "active" ->
        group_error(operation, "group_not_active", source_group.group_id)

      destination_group.status != "active" ->
        group_error(operation, "group_not_active", destination_group.group_id)

      not positive_integer?(operation["amount_cents"]) ->
        rejected(operation, "invalid_amount")

      true ->
        transfer_funding(
          operation,
          source_group,
          destination_group,
          operation["amount_cents"]
        )
    end
  end

  defp transfer_funding(operation, source_group, destination_group, amount) do
    source_allocations = active_funding_allocations(source_group.id)
    held_cents = Enum.sum(Enum.map(source_allocations, & &1.amount_cents))
    destination_totals = group_totals(destination_group.id)

    destination_outstanding =
      destination_totals.deposit_due_cents - destination_totals.deposit_paid_cents

    cond do
      amount > held_cents ->
        rejected(operation, "transfer_exceeds_held_funding")

      amount > destination_outstanding ->
        rejected(operation, "transfer_exceeds_outstanding")

      true ->
        parts = take_funding_parts(source_allocations, amount)
        segments = destination_funding_segments(destination_group.id, parts)
        %{cash: cash_cents, credit: credit_cents} = funding_amounts(parts)

        deltas = %{
          source_group.id => {-cash_cents, -credit_cents},
          destination_group.id => {cash_cents, credit_cents}
        }

        case update_groups_for_funding([source_group, destination_group], deltas) do
          {:ok, updated_groups} ->
            remove_funding_parts(parts)
            insert_transferred_funding_allocations(destination_group.id, segments)
            mark_cash_sources_transferred(parts)

            record_cash_movement(
              operation,
              source_group.property_id,
              "transferred_out",
              cash_cents
            )

            record_cash_movement(
              operation,
              destination_group.property_id,
              "transferred_in",
              cash_cents
            )

            source_totals = group_totals(source_group.id)
            destination_totals = group_totals(destination_group.id)

            applied(operation, %{
              source_group_id: source_group.group_id,
              destination_group_id: destination_group.group_id,
              amount_cents: amount,
              source_outstanding_deposit_cents:
                source_totals.deposit_due_cents - source_totals.deposit_paid_cents,
              destination_outstanding_deposit_cents:
                destination_totals.deposit_due_cents - destination_totals.deposit_paid_cents,
              source_revision: Map.fetch!(updated_groups, source_group.id).revision,
              destination_revision: Map.fetch!(updated_groups, destination_group.id).revision
            })

          :retry ->
            :retry
        end
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, _occurred_on} <- common_date(operation),
         {:ok, payment_operation_id} <- payment_operation_id(operation),
         {:ok, source} <- reducible_payment_source(operation, payment_operation_id),
         %Group{} = group <- Repo.get(Group, source.group_id) do
      apply_to_payment_group(operation, group, fn current_group ->
        amount = operation["amount_cents"]
        held_cents = held_cash_for_source(source.id)

        cond do
          not positive_integer?(amount) ->
            {:error, group_error(operation, "invalid_amount", current_group.group_id)}

          held_cents == 0 ->
            {:error, group_error(operation, "payment_not_reducible", current_group.group_id)}

          amount > held_cents ->
            {:error,
             group_error(operation, "reduction_exceeds_held_cash", current_group.group_id)}

          true ->
            parts = take_cash_funding_parts(source.id, amount)

            case update_groups_for_cash_correction(current_group, parts) do
              {:ok, updated_groups} ->
                remove_funding_parts(parts)

                Repo.update_all(
                  from(current in CashPaymentSource, where: current.id == ^source.id),
                  inc: [reduced_cents: amount]
                )

                record_cash_movements(operation, cash_amounts_by_property(parts), "reduced")

                totals = group_totals(current_group.id)

                applied(operation, %{
                  payment_operation_id: payment_operation_id,
                  group_id: current_group.group_id,
                  amount_cents: amount,
                  outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents,
                  revision: Map.fetch!(updated_groups, current_group.id).revision
                })

              :retry ->
                :retry
            end
        end
      end)
    else
      {:error, result} -> result
      nil -> rejected(operation, "operation_not_found")
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, _occurred_on} <- common_date(operation),
         {:ok, payment_operation_id} <- payment_operation_id(operation),
         {:ok, source} <- chargeable_payment_source(operation, payment_operation_id),
         %Group{} = group <- Repo.get(Group, source.group_id) do
      apply_to_payment_group(operation, group, fn current_group ->
        chargeable_cents = source.recorded_cents - source.reduced_cents

        if chargeable_cents <= 0 or source.charged_back_cents > 0 do
          {:error, group_error(operation, "payment_not_chargeable", current_group.group_id)}
        else
          held_cents = held_cash_for_source(source.id)
          parts = take_cash_funding_parts(source.id, held_cents)

          case update_groups_for_cash_correction(current_group, parts) do
            {:ok, updated_groups} ->
              remove_funding_parts(parts)
              record_cash_movements(operation, cash_amounts_by_property(parts), "charged_back")
              charge_back_cash_dispositions(operation, source.id)
              revoke_credit_entitlements(operation, source.id)

              Repo.update_all(
                from(current in CashPaymentSource, where: current.id == ^source.id),
                set: [refunded_cents: 0, retained_cents: 0, converted_to_credit_cents: 0],
                inc: [charged_back_cents: chargeable_cents]
              )

              totals = group_totals(current_group.id)

              applied(operation, %{
                payment_operation_id: payment_operation_id,
                group_id: current_group.group_id,
                charged_back_cents: chargeable_cents,
                outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents,
                revision: Map.fetch!(updated_groups, current_group.id).revision
              })

            :retry ->
              :retry
          end
        end
      end)
    else
      {:error, result} -> result
      nil -> rejected(operation, "operation_not_found")
    end
  end

  defp cancel_selected_rooms(operation, group, occurred_on, rooms, include_room_ids?) do
    refund_method = refund_method(operation)

    cond do
      refund_method == :invalid ->
        {:error, group_error(operation, "refund_method_not_available", group.group_id)}

      refund_method == :hotel_credit and not refundable?(group, occurred_on) ->
        {:error, group_error(operation, "refund_method_not_available", group.group_id)}

      true ->
        room_ids = Enum.map(rooms, & &1.id)
        cash_allocations = cash_allocations_for_rooms(room_ids, :forward)
        credit_allocations = credit_allocations_for_rooms(room_ids)
        cash_paid_cents = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
        credit_paid_cents = Enum.sum(Enum.map(credit_allocations, & &1.amount_cents))
        refundable? = refundable?(group, occurred_on)

        {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
          cancellation_amounts(refundable?, refund_method, cash_paid_cents)

        totals = group_totals(group.id)
        cancelled_lodging = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
        cancelled_due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))
        active_after = active_room_count(group.id) - length(rooms)

        changes = [
          status: if(active_after == 0, do: "cancelled", else: "active"),
          lodging_total_cents: totals.lodging_total_cents - cancelled_lodging,
          deposit_due_cents: totals.deposit_due_cents - cancelled_due,
          deposit_paid_cents: totals.deposit_paid_cents - cash_paid_cents - credit_paid_cents,
          cash_paid_cents: totals.cash_paid_cents - cash_paid_cents,
          credit_paid_cents: totals.credit_paid_cents - credit_paid_cents,
          refunded_cents: group.refunded_cents + refunded_cents,
          retained_cents: group.retained_cents + retained_cents,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted_cents
        ]

        {:update, changes,
         fn updated ->
           result = %{
             group_id: updated.group_id,
             refunded_cents: refunded_cents,
             retained_cents: retained_cents,
             credit_issued_cents: credit_issued_cents,
             revision: updated.revision
           }

           result =
             if include_room_ids? do
               Map.put(result, :cancelled_room_ids, Enum.map(rooms, & &1.room_id))
             else
               result
             end

           applied(operation, result)
         end,
         fn _updated ->
           settle_cash_allocations(
             operation,
             cash_allocations,
             group.property_id,
             refunded_cents,
             retained_cents,
             converted_cents
           )

           if refundable? do
             restore_credit_allocations(operation, credit_allocations, occurred_on)
           else
             consume_credit_allocations(operation, credit_allocations)
           end

           Repo.update_all(from(room in Room, where: room.id in ^room_ids),
             set: [status: "cancelled"]
           )

           if credit_issued_cents > 0 do
             lot =
               create_credit_lot(
                 group.guest_id,
                 operation["operation_id"],
                 credit_issued_cents,
                 Date.add(occurred_on, 365)
               )

             create_credit_entitlements(cash_allocations, lot.id)
             record_issued_credit(operation, lot)
           end

           :ok
         end}
    end
  end

  defp settle_cash_allocations(
         operation,
         cash_allocations,
         property_id,
         refunded_cents,
         retained_cents,
         converted_cents
       ) do
    source_amounts = source_amounts(cash_allocations)

    {disposition, movement_type, movement_cents} =
      cond do
        refunded_cents > 0 -> {"refunded", "refunded", refunded_cents}
        retained_cents > 0 -> {"retained", "retained", retained_cents}
        converted_cents > 0 -> {"converted", "converted_to_credit", converted_cents}
        true -> {nil, nil, 0}
      end

    Enum.each(source_amounts, fn {source_id, amount_cents} ->
      changes =
        cond do
          refunded_cents > 0 -> [refunded_cents: amount_cents]
          retained_cents > 0 -> [retained_cents: amount_cents]
          converted_cents > 0 -> [converted_to_credit_cents: amount_cents]
          true -> []
        end

      if changes != [] do
        Repo.update_all(from(source in CashPaymentSource, where: source.id == ^source_id),
          inc: changes
        )

        Repo.insert!(%CashPaymentDisposition{
          cash_payment_source_id: source_id,
          property_id: property_id,
          disposition: disposition,
          amount_cents: amount_cents
        })
      end
    end)

    record_cash_movement(operation, property_id, movement_type, movement_cents)

    allocation_ids = Enum.map(cash_allocations, & &1.id)

    Repo.delete_all(
      from(allocation in CashRoomAllocation, where: allocation.id in ^allocation_ids)
    )
  end

  defp apply_to_group(operation, group_id, action) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> group_error(operation, "group_not_found", group_id)
      group -> apply_to_loaded_group(operation, group, action)
    end
  end

  defp apply_to_loaded_group(operation, group, action) do
    if stale_revision?(operation, group) do
      stale_revision_error(operation, group)
    else
      case action.(group) do
        {:error, result} ->
          result

        {:update, changes, result_builder} ->
          update_group_and_build_result(operation, group, changes, result_builder)

        {:update, changes, result_builder, after_update} ->
          update_group_and_build_result(operation, group, changes, result_builder, after_update)
      end
    end
  end

  defp apply_to_payment_group(operation, group, action) do
    if stale_revision?(operation, group) do
      stale_revision_error(operation, group)
    else
      case action.(group) do
        {:error, result} -> result
        result -> result
      end
    end
  end

  defp update_group_and_build_result(
         operation,
         group,
         changes,
         result_builder,
         after_update \\ fn _updated -> :ok end
       ) do
    case update_group(group, changes) do
      {:ok, updated} ->
        case after_update.(updated) do
          :ok -> result_builder.(updated)
          :retry -> :retry
        end

      {:conflict, latest} ->
        if has_expected_revision?(operation) do
          stale_revision_error(operation, latest)
        else
          :retry
        end
    end
  end

  defp update_group(group, changes) do
    changeset =
      group
      |> change(changes)
      # Ledger-only corrections still advance the group's revision even when its room totals stay put.
      |> force_change(:revision, group.revision)
      |> optimistic_lock(:revision)

    case Repo.update(changeset, stale_error_field: :revision) do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:conflict, Repo.get!(Group, group.id)}
    end
  end

  defp update_groups_for_cash_correction(payment_group, parts) do
    cash_deltas =
      Enum.reduce(parts, %{}, fn part, deltas ->
        Map.update(deltas, part.group_id, -part.amount_cents, &(&1 - part.amount_cents))
      end)

    deltas =
      Map.new(cash_deltas, fn {group_id, cash_delta} -> {group_id, {cash_delta, 0}} end)
      |> Map.put_new(payment_group.id, {0, 0})

    affected_groups =
      parts
      |> Enum.map(& &1.group_id)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == payment_group.id))
      |> Enum.map(&Repo.get!(Group, &1))

    update_groups_for_funding([payment_group | affected_groups], deltas)
  end

  defp update_groups_for_funding(groups, deltas) do
    groups
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce_while({:ok, %{}}, fn group, {:ok, updated_groups} ->
      {cash_delta, credit_delta} = Map.fetch!(deltas, group.id)
      totals = group_totals(group.id)

      case update_group(group, payment_total_changes(group, totals, cash_delta, credit_delta)) do
        {:ok, updated} ->
          {:cont, {:ok, Map.put(updated_groups, group.id, updated)}}

        {:conflict, _latest} ->
          {:halt, :retry}
      end
    end)
  end

  defp open_attributes(operation, booked_on) do
    required = [
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         Enum.all?(["group_id", "guest_id", "property_id"], &valid_identifier?(operation[&1])) do
      with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
           {:ok, departure_on} <- parse_date(operation["departure_on"]),
           :ok <- valid_stay(arrival_on, departure_on),
           :ok <- valid_rate_plan(operation["rate_plan"]),
           {:ok, rooms, lodging_total_cents, deposit_due_cents} <-
             build_rooms(
               operation["rooms"],
               Date.diff(departure_on, arrival_on),
               operation["rate_plan"]
             ) do
        {:ok,
         %{
           group_id: operation["group_id"],
           guest_id: operation["guest_id"],
           property_id: operation["property_id"],
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: operation["rate_plan"],
           policy_version: policy_version_for(operation["rate_plan"], booked_on),
           status: "active",
           revision: 1,
           lodging_total_cents: lodging_total_cents,
           deposit_due_cents: deposit_due_cents,
           deposit_paid_cents: 0,
           cash_paid_cents: 0,
           credit_paid_cents: 0,
           refunded_cents: 0,
           retained_cents: 0,
           cash_converted_to_credit_cents: 0
         }, rooms}
      else
        :invalid_stay ->
          {:error, group_error(operation, "invalid_stay", operation["group_id"])}

        :invalid_rate_plan ->
          {:error, group_error(operation, "invalid_rate_plan", operation["group_id"])}

        :invalid_rooms ->
          {:error, group_error(operation, "invalid_rooms", operation["group_id"])}

        _ ->
          {:error, group_error(operation, "invalid_stay", operation["group_id"])}
      end
    else
      {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp build_rooms(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    room_data =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        if is_map(room) and valid_identifier?(room["room_id"]) and
             positive_integer?(room["nightly_rate_cents"]) do
          lodging_total_cents = room["nightly_rate_cents"] * nights

          %{
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            position: position,
            lodging_total_cents: lodging_total_cents,
            deposit_due_cents: deposit_for(lodging_total_cents, rate_plan),
            status: "active"
          }
        else
          :invalid
        end
      end)

    if :invalid in room_data or duplicate_room_ids?(room_data) do
      :invalid_rooms
    else
      lodging_total_cents = Enum.sum(Enum.map(room_data, & &1.lodging_total_cents))
      deposit_due_cents = Enum.sum(Enum.map(room_data, & &1.deposit_due_cents))
      {:ok, room_data, lodging_total_cents, deposit_due_cents}
    end
  end

  defp build_rooms(_, _, _), do: :invalid_rooms

  defp duplicate_room_ids?(rooms) do
    room_ids = Enum.map(rooms, & &1.room_id)
    length(room_ids) != MapSet.size(MapSet.new(room_ids))
  end

  defp group_totals(group_id) do
    room_balances(group_id)
    |> Enum.filter(&(&1.room.status == "active"))
    |> Enum.reduce(
      %{
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      },
      fn balance, totals ->
        %{
          lodging_total_cents: totals.lodging_total_cents + balance.room.lodging_total_cents,
          deposit_due_cents: totals.deposit_due_cents + balance.room.deposit_due_cents,
          deposit_paid_cents:
            totals.deposit_paid_cents + balance.cash_paid_cents + balance.credit_paid_cents,
          cash_paid_cents: totals.cash_paid_cents + balance.cash_paid_cents,
          credit_paid_cents: totals.credit_paid_cents + balance.credit_paid_cents
        }
      end
    )
  end

  defp room_balances(group_id) do
    rooms =
      Repo.all(from(room in Room, where: room.group_id == ^group_id, order_by: room.position))

    cash_by_room =
      Repo.all(
        from(allocation in CashRoomAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.group_id == ^group_id,
          group_by: allocation.room_id,
          select: {allocation.room_id, sum(allocation.amount_cents)}
        )
      )
      |> Map.new()

    credit_by_room =
      Repo.all(
        from(allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.group_id == ^group_id,
          group_by: allocation.room_id,
          select: {allocation.room_id, sum(allocation.amount_cents)}
        )
      )
      |> Map.new()

    Enum.map(rooms, fn room ->
      %{
        room: room,
        cash_paid_cents: Map.get(cash_by_room, room.id, 0),
        credit_paid_cents: Map.get(credit_by_room, room.id, 0)
      }
    end)
  end

  defp active_rooms(group_id) do
    Repo.all(
      from(room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: room.position
      )
    )
  end

  defp active_room_count(group_id) do
    Repo.aggregate(
      from(room in Room, where: room.group_id == ^group_id and room.status == "active"),
      :count
    )
  end

  defp selected_active_rooms(group_id, room_ids)
       when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &valid_identifier?/1) and
         length(room_ids) == MapSet.size(MapSet.new(room_ids)) do
      rooms =
        Repo.all(
          from(room in Room,
            where:
              room.group_id == ^group_id and room.status == "active" and room.room_id in ^room_ids,
            order_by: room.position
          )
        )

      if length(rooms) == length(room_ids), do: {:ok, rooms}, else: :error
    else
      :error
    end
  end

  defp selected_active_rooms(_, _), do: :error

  defp funding_room_segments(group_id, amount) do
    capacities =
      room_balances(group_id)
      |> Enum.filter(&(&1.room.status == "active"))
      |> Enum.map(fn balance ->
        {balance.room.id,
         balance.room.deposit_due_cents - balance.cash_paid_cents - balance.credit_paid_cents}
      end)

    {segments, 0, _capacities} = take_capacity(capacities, amount)
    segments
  end

  defp credit_room_segments(group_id, redemptions) do
    capacities =
      room_balances(group_id)
      |> Enum.filter(&(&1.room.status == "active"))
      |> Enum.map(fn balance ->
        {balance.room.id,
         balance.room.deposit_due_cents - balance.cash_paid_cents - balance.credit_paid_cents}
      end)

    {segments, _capacities} =
      Enum.reduce(redemptions, {[], capacities}, fn {lot, amount_cents}, {segments, capacities} ->
        {new_segments, 0, capacities} = take_capacity(capacities, amount_cents)

        {segments ++ Enum.map(new_segments, fn {room_id, cents} -> {room_id, lot.id, cents} end),
         capacities}
      end)

    segments
  end

  defp active_funding_allocations(group_id) do
    cash_allocations =
      Repo.all(
        from(allocation in CashRoomAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.group_id == ^group_id and room.status == "active",
          select: %{
            id: allocation.id,
            group_id: room.group_id,
            room_id: allocation.room_id,
            source_id: allocation.cash_payment_source_id,
            amount_cents: allocation.amount_cents,
            allocation_order: allocation.allocation_order
          }
        )
      )
      |> Enum.map(&Map.put(&1, :kind, :cash))

    credit_allocations =
      Repo.all(
        from(allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.group_id == ^group_id and room.status == "active",
          select: %{
            id: allocation.id,
            group_id: room.group_id,
            room_id: allocation.room_id,
            lot_id: allocation.hotel_credit_lot_id,
            amount_cents: allocation.amount_cents,
            allocation_order: allocation.allocation_order
          }
        )
      )
      |> Enum.map(&Map.put(&1, :kind, :credit))

    Enum.sort_by(cash_allocations ++ credit_allocations, & &1.allocation_order, :desc)
  end

  defp take_cash_funding_parts(source_id, amount) do
    source_id
    |> active_cash_allocations_for_source()
    |> take_funding_parts(amount)
  end

  defp active_cash_allocations_for_source(source_id) do
    Repo.all(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.cash_payment_source_id == ^source_id and room.status == "active",
        order_by: [desc: allocation.allocation_order],
        select: %{
          id: allocation.id,
          group_id: room.group_id,
          room_id: allocation.room_id,
          source_id: allocation.cash_payment_source_id,
          amount_cents: allocation.amount_cents,
          allocation_order: allocation.allocation_order,
          kind: :cash
        }
      )
    )
  end

  defp take_funding_parts(allocations, amount) do
    {parts, 0} =
      Enum.reduce_while(allocations, {[], amount}, fn allocation, {parts, remaining} ->
        moved_cents = min(remaining, allocation.amount_cents)

        part =
          allocation
          |> Map.put(:original_amount_cents, allocation.amount_cents)
          |> Map.put(:amount_cents, moved_cents)

        if moved_cents == remaining do
          {:halt, {[part | parts], 0}}
        else
          {:cont, {[part | parts], remaining - moved_cents}}
        end
      end)

    Enum.reverse(parts)
  end

  defp destination_funding_segments(group_id, parts) do
    capacities =
      room_balances(group_id)
      |> Enum.filter(&(&1.room.status == "active"))
      |> Enum.map(fn balance ->
        {balance.room.id,
         balance.room.deposit_due_cents - balance.cash_paid_cents - balance.credit_paid_cents}
      end)

    {segments, _capacities} =
      Enum.reduce(parts, {[], capacities}, fn part, {segments, capacities} ->
        {room_segments, 0, capacities} = take_capacity(capacities, part.amount_cents)

        transferred_segments =
          Enum.map(room_segments, fn {room_id, amount_cents} ->
            part
            |> Map.put(:room_id, room_id)
            |> Map.put(:amount_cents, amount_cents)
          end)

        {segments ++ transferred_segments, capacities}
      end)

    segments
  end

  defp funding_amounts(parts) do
    Enum.reduce(parts, %{cash: 0, credit: 0}, fn part, amounts ->
      Map.update!(amounts, part.kind, &(&1 + part.amount_cents))
    end)
  end

  defp remove_funding_parts(parts) do
    Enum.each(parts, fn part ->
      if part.amount_cents == part.original_amount_cents do
        case part.kind do
          :cash ->
            {1, _} =
              Repo.delete_all(
                from(allocation in CashRoomAllocation, where: allocation.id == ^part.id)
              )

          :credit ->
            {1, _} =
              Repo.delete_all(
                from(allocation in CreditAllocation, where: allocation.id == ^part.id)
              )
        end
      else
        case part.kind do
          :cash ->
            {1, _} =
              Repo.update_all(
                from(allocation in CashRoomAllocation,
                  where:
                    allocation.id == ^part.id and allocation.amount_cents >= ^part.amount_cents
                ),
                inc: [amount_cents: -part.amount_cents]
              )

          :credit ->
            {1, _} =
              Repo.update_all(
                from(allocation in CreditAllocation,
                  where:
                    allocation.id == ^part.id and allocation.amount_cents >= ^part.amount_cents
                ),
                inc: [amount_cents: -part.amount_cents]
              )
        end
      end
    end)
  end

  defp insert_transferred_funding_allocations(group_id, segments) do
    rows =
      segments
      |> Enum.zip(next_allocation_orders(length(segments)))
      |> Enum.map(fn {segment, allocation_order} ->
        Map.put(segment, :allocation_order, allocation_order)
      end)

    {cash_rows, credit_rows} = Enum.split_with(rows, &(&1.kind == :cash))

    insert_allocation_rows(
      CashRoomAllocation,
      Enum.map(cash_rows, fn row ->
        %{
          room_id: row.room_id,
          cash_payment_source_id: row.source_id,
          amount_cents: row.amount_cents,
          allocation_order: row.allocation_order
        }
      end)
    )

    insert_allocation_rows(
      CreditAllocation,
      Enum.map(credit_rows, fn row ->
        %{
          group_id: group_id,
          room_id: row.room_id,
          hotel_credit_lot_id: row.lot_id,
          amount_cents: row.amount_cents,
          allocation_order: row.allocation_order
        }
      end)
    )
  end

  defp mark_cash_sources_transferred(parts) do
    source_ids =
      parts
      |> Enum.filter(&(&1.kind == :cash))
      |> Enum.map(& &1.source_id)
      |> Enum.uniq()

    if source_ids != [] do
      Repo.update_all(
        from(source in CashPaymentSource, where: source.id in ^source_ids),
        set: [participated_in_transfer: true]
      )
    end
  end

  defp take_capacity(capacities, amount) do
    Enum.reduce_while(capacities, {[], amount, []}, fn {room_id, capacity},
                                                       {segments, remaining, done} ->
      cents = min(capacity, remaining)
      segments = if cents > 0, do: segments ++ [{room_id, cents}], else: segments
      updated = {room_id, capacity - cents}

      if cents == remaining do
        {:halt, {segments, 0, done ++ [updated]}}
      else
        {:cont, {segments, remaining - cents, done ++ [updated]}}
      end
    end)
    |> then(fn {segments, remaining, updated_prefix} ->
      updated_capacities = updated_prefix ++ Enum.drop(capacities, length(updated_prefix))
      {segments, remaining, updated_capacities}
    end)
  end

  defp payment_total_changes(group, totals, cash_delta, credit_delta) do
    [
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents + cash_delta + credit_delta,
      cash_paid_cents: totals.cash_paid_cents + cash_delta,
      credit_paid_cents: totals.credit_paid_cents + credit_delta,
      refunded_cents: group.refunded_cents,
      retained_cents: group.retained_cents,
      cash_converted_to_credit_cents: group.cash_converted_to_credit_cents
    ]
  end

  defp insert_cash_room_allocations(source_id, segments) do
    rows =
      segments
      |> Enum.zip(next_allocation_orders(length(segments)))
      |> Enum.map(fn {{room_id, amount_cents}, allocation_order} ->
        %{
          room_id: room_id,
          cash_payment_source_id: source_id,
          amount_cents: amount_cents,
          allocation_order: allocation_order
        }
      end)

    insert_allocation_rows(CashRoomAllocation, rows)
  end

  defp insert_credit_room_allocations(group_id, segments) do
    rows =
      segments
      |> Enum.zip(next_allocation_orders(length(segments)))
      |> Enum.map(fn {{room_id, lot_id, amount_cents}, allocation_order} ->
        %{
          group_id: group_id,
          room_id: room_id,
          hotel_credit_lot_id: lot_id,
          amount_cents: amount_cents,
          allocation_order: allocation_order
        }
      end)

    insert_allocation_rows(CreditAllocation, rows)
  end

  defp insert_allocation_rows(_schema, []), do: :ok

  defp insert_allocation_rows(schema, rows) do
    case Repo.insert_all(schema, rows) do
      {count, _} when count == length(rows) -> :ok
      _ -> raise "could not create room allocations"
    end
  end

  defp next_allocation_orders(0), do: []

  defp next_allocation_orders(count) do
    highest_order =
      max(
        Repo.aggregate(CashRoomAllocation, :max, :allocation_order) || 0,
        Repo.aggregate(CreditAllocation, :max, :allocation_order) || 0
      )

    Enum.to_list((highest_order + 1)..(highest_order + count))
  end

  defp cash_allocations_for_rooms(room_ids, :forward) do
    Repo.all(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.room_id in ^room_ids,
        order_by: [asc: room.position, asc: allocation.id],
        select: %{
          id: allocation.id,
          source_id: allocation.cash_payment_source_id,
          room_id: allocation.room_id,
          amount_cents: allocation.amount_cents
        }
      )
    )
  end

  defp credit_allocations_for_rooms(room_ids) do
    Repo.all(
      from(allocation in CreditAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.room_id in ^room_ids,
        order_by: [asc: room.position, asc: allocation.id],
        select: %{
          id: allocation.id,
          lot_id: allocation.hotel_credit_lot_id,
          amount_cents: allocation.amount_cents
        }
      )
    )
  end

  defp source_amounts(allocations) do
    Enum.reduce(allocations, %{}, fn allocation, amounts ->
      Map.update(
        amounts,
        allocation.source_id,
        allocation.amount_cents,
        &(&1 + allocation.amount_cents)
      )
    end)
  end

  defp charge_back_cash_dispositions(operation, source_id) do
    Repo.all(
      from(disposition in CashPaymentDisposition,
        where: disposition.cash_payment_source_id == ^source_id
      )
    )
    |> Enum.each(fn disposition ->
      movement_type =
        case disposition.disposition do
          "refunded" -> "refunded"
          "retained" -> "retained"
          "converted" -> "converted_to_credit"
        end

      record_cash_movement(
        operation,
        disposition.property_id,
        movement_type,
        -disposition.amount_cents
      )

      record_cash_movement(
        operation,
        disposition.property_id,
        "charged_back",
        disposition.amount_cents
      )
    end)
  end

  defp cash_amounts_by_property(parts) do
    group_properties =
      parts
      |> Enum.map(& &1.group_id)
      |> Enum.uniq()
      |> then(fn group_ids ->
        Repo.all(
          from(group in Group,
            where: group.id in ^group_ids,
            select: {group.id, group.property_id}
          )
        )
      end)
      |> Map.new()

    Enum.reduce(parts, %{}, fn part, amounts ->
      property_id = Map.fetch!(group_properties, part.group_id)
      Map.update(amounts, property_id, part.amount_cents, &(&1 + part.amount_cents))
    end)
  end

  defp record_cash_movements(operation, amounts_by_property, movement_type) do
    Enum.each(amounts_by_property, fn {property_id, amount_cents} ->
      record_cash_movement(operation, property_id, movement_type, amount_cents)
    end)
  end

  defp record_cash_movement(_operation, _property_id, _movement_type, amount_cents)
       when amount_cents in [nil, 0],
       do: :ok

  defp record_cash_movement(operation, property_id, movement_type, amount_cents) do
    case reporting_posting_on(operation) do
      nil ->
        :ok

      posting_on ->
        Repo.insert!(%FinanceCashMovement{
          posting_on: posting_on,
          property_id: property_id,
          movement_type: movement_type,
          amount_cents: amount_cents
        })

        :ok
    end
  end

  defp record_credit_availability_redemptions(operation, redemptions) do
    Enum.each(redemptions, fn {lot, amount_cents} ->
      record_credit_availability_movement(operation, lot.id, -amount_cents)
    end)
  end

  defp record_credit_availability_movement(_operation, _lot_id, amount_cents)
       when amount_cents in [nil, 0],
       do: :ok

  defp record_credit_availability_movement(operation, lot_id, amount_cents) do
    case reporting_posting_on(operation) do
      nil ->
        :ok

      posting_on ->
        Repo.insert!(%FinanceCreditAvailabilityMovement{
          posting_on: posting_on,
          hotel_credit_lot_id: lot_id,
          amount_cents: amount_cents
        })

        :ok
    end
  end

  defp record_credit_movement(_operation, _movement_type, amount_cents)
       when amount_cents in [nil, 0],
       do: :ok

  defp record_credit_movement(operation, movement_type, amount_cents) do
    case reporting_posting_on(operation) do
      nil ->
        :ok

      posting_on ->
        Repo.insert!(%FinanceCreditMovement{
          posting_on: posting_on,
          movement_type: movement_type,
          amount_cents: amount_cents
        })

        :ok
    end
  end

  defp record_issued_credit(operation, lot) do
    record_credit_movement(operation, "issued", lot.remaining_cents)

    if credit_active_on_posting_date?(operation, lot) do
      record_credit_availability_movement(operation, lot.id, lot.remaining_cents)
    else
      record_credit_movement(operation, "expired", lot.remaining_cents)
    end
  end

  defp credit_active_on_posting_date?(operation, lot) do
    case reporting_posting_on(operation) do
      nil -> true
      posting_on -> Date.compare(lot.expires_on, posting_on) != :lt
    end
  end

  defp reporting_posting_on(operation) do
    with %FinanceReporting{} = finance_reporting <- reporting(),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      if Date.compare(occurred_on, finance_reporting.starts_on) == :lt do
        finance_reporting.starts_on
      else
        occurred_on
      end
    else
      _ -> nil
    end
  end

  defp reporting, do: Repo.one(FinanceReporting)

  defp snapshot_finance_cash_openings(finance_reporting) do
    rows =
      Repo.all(
        from(allocation in CashRoomAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          join: group in Group,
          on: group.id == room.group_id,
          where: room.status == "active",
          group_by: group.property_id,
          select: {group.property_id, sum(allocation.amount_cents)}
        )
      )
      |> Enum.map(fn {property_id, opening_held_cents} ->
        %{
          finance_reporting_id: finance_reporting.id,
          property_id: property_id,
          opening_held_cents: opening_held_cents
        }
      end)

    if rows != [] do
      {count, _} = Repo.insert_all(FinanceCashOpening, rows)
      if count != length(rows), do: raise("could not snapshot finance cash openings")
    end
  end

  defp snapshot_finance_credit_lot_openings(finance_reporting) do
    rows =
      Repo.all(
        from(lot in HotelCreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^finance_reporting.starts_on,
          select: {lot.id, lot.remaining_cents}
        )
      )
      |> Enum.map(fn {lot_id, opening_available_cents} ->
        %{
          finance_reporting_id: finance_reporting.id,
          hotel_credit_lot_id: lot_id,
          opening_available_cents: opening_available_cents
        }
      end)

    if rows != [] do
      {count, _} = Repo.insert_all(FinanceCreditLotOpening, rows)
      if count != length(rows), do: raise("could not snapshot finance credit lot openings")
    end
  end

  defp daily_cash_report(finance_reporting, date) do
    opening_by_property =
      Repo.all(
        from(opening in FinanceCashOpening,
          where: opening.finance_reporting_id == ^finance_reporting.id,
          select: {opening.property_id, opening.opening_held_cents}
        )
      )
      |> Map.new()

    movements =
      Repo.all(from(movement in FinanceCashMovement, where: movement.posting_on <= ^date))

    properties =
      (Map.keys(opening_by_property) ++ Enum.map(movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(properties, fn property_id ->
      property_movements = Enum.filter(movements, &(&1.property_id == property_id))

      opening_held_cents =
        Map.get(opening_by_property, property_id, 0) +
          cash_balance_change(
            Enum.filter(property_movements, &(Date.compare(&1.posting_on, date) == :lt))
          )

      movements =
        property_movements
        |> Enum.filter(&(Date.compare(&1.posting_on, date) == :eq))
        |> cash_movement_totals()

      closing_held_cents = opening_held_cents + cash_balance_change(movements)

      if opening_held_cents != 0 or closing_held_cents != 0 or
           Enum.any?(Map.values(movements), &(&1 != 0)) do
        [
          %{
            property_id: property_id,
            opening_held_cents: opening_held_cents,
            movements: movements,
            closing_held_cents: closing_held_cents
          }
        ]
      else
        []
      end
    end)
  end

  defp daily_credit_report(finance_reporting, date) do
    movements = credit_movements_through(finance_reporting, date)

    opening_liability_cents =
      finance_reporting.opening_credit_liability_cents +
        credit_balance_change(Enum.filter(movements, &(Date.compare(&1.posting_on, date) == :lt)))

    movements =
      movements
      |> Enum.filter(&(Date.compare(&1.posting_on, date) == :eq))
      |> credit_movement_totals()

    %{
      opening_liability_cents: opening_liability_cents,
      movements: movements,
      closing_liability_cents: opening_liability_cents + credit_balance_change(movements)
    }
  end

  defp credit_movements_through(finance_reporting, date) do
    Repo.all(from(movement in FinanceCreditMovement, where: movement.posting_on <= ^date)) ++
      credit_expiry_movements_through(finance_reporting, date)
  end

  defp credit_expiry_movements_through(finance_reporting, date) do
    latest_expiry_on = Date.add(date, -1)

    if Date.compare(latest_expiry_on, finance_reporting.starts_on) == :lt do
      []
    else
      lots =
        Repo.all(
          from(lot in HotelCreditLot,
            where:
              lot.expires_on >= ^finance_reporting.starts_on and
                lot.expires_on <= ^latest_expiry_on
          )
        )

      opening_by_lot =
        Repo.all(
          from(opening in FinanceCreditLotOpening,
            where: opening.finance_reporting_id == ^finance_reporting.id,
            select: {opening.hotel_credit_lot_id, opening.opening_available_cents}
          )
        )
        |> Map.new()

      availability_movements =
        Repo.all(
          from(movement in FinanceCreditAvailabilityMovement,
            where: movement.posting_on <= ^latest_expiry_on
          )
        )

      Enum.flat_map(lots, fn lot ->
        expired_cents =
          Map.get(opening_by_lot, lot.id, 0) +
            Enum.sum_by(
              Enum.filter(availability_movements, fn movement ->
                movement.hotel_credit_lot_id == lot.id and
                  Date.compare(movement.posting_on, lot.expires_on) != :gt
              end),
              & &1.amount_cents
            )

        if expired_cents > 0 do
          [
            %{
              posting_on: Date.add(lot.expires_on, 1),
              movement_type: "expired",
              amount_cents: expired_cents
            }
          ]
        else
          []
        end
      end)
    end
  end

  defp cash_movement_totals(movements) do
    totals = Map.new(@cash_movement_types, &{"#{&1}_cents", 0})

    Enum.reduce(movements, totals, fn movement, totals ->
      Map.update!(totals, "#{movement.movement_type}_cents", &(&1 + movement.amount_cents))
    end)
  end

  defp credit_movement_totals(movements) do
    totals = Map.new(@credit_movement_types, &{"#{&1}_cents", 0})

    Enum.reduce(movements, totals, fn movement, totals ->
      Map.update!(totals, "#{movement.movement_type}_cents", &(&1 + movement.amount_cents))
    end)
  end

  defp cash_balance_change(movements) when is_list(movements) do
    movements
    |> cash_movement_totals()
    |> cash_balance_change()
  end

  defp cash_balance_change(movements) do
    movements["received_cents"] + movements["transferred_in_cents"] -
      movements["transferred_out_cents"] - movements["refunded_cents"] -
      movements["retained_cents"] - movements["converted_to_credit_cents"] -
      movements["reduced_cents"] - movements["charged_back_cents"]
  end

  defp credit_balance_change(movements) when is_list(movements) do
    movements
    |> credit_movement_totals()
    |> credit_balance_change()
  end

  defp credit_balance_change(movements) do
    movements["issued_cents"] - movements["expired_cents"] - movements["consumed_cents"] -
      movements["revoked_cents"] - movements["absorbed_cents"]
  end

  defp held_cash_for_source(source_id) do
    Repo.aggregate(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.cash_payment_source_id == ^source_id and room.status == "active"
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  defp held_cash_by_group(source_id) do
    Repo.all(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.id == room.group_id,
        where: allocation.cash_payment_source_id == ^source_id and room.status == "active",
        group_by: group.group_id,
        order_by: group.group_id,
        select: %{group_id: group.group_id, amount_cents: sum(allocation.amount_cents)}
      )
    )
  end

  defp reducible_payment_source(operation, payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, rejected(operation, "operation_not_found")}

      operation_record ->
        if applied_cash_payment?(operation_record) do
          case Repo.get_by(CashPaymentSource, payment_operation_id: payment_operation_id) do
            nil -> {:error, rejected(operation, "payment_not_reducible")}
            source -> {:ok, source}
          end
        else
          {:error, rejected(operation, "payment_not_reducible")}
        end
    end
  end

  defp chargeable_payment_source(operation, payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, rejected(operation, "operation_not_found")}

      operation_record ->
        if applied_cash_payment?(operation_record) do
          case Repo.get_by(CashPaymentSource, payment_operation_id: payment_operation_id) do
            nil -> {:error, rejected(operation, "payment_not_chargeable")}
            source -> {:ok, source}
          end
        else
          {:error, rejected(operation, "payment_not_chargeable")}
        end
    end
  end

  defp applied_cash_payment?(operation) do
    operation.operation_type == "record_cash_payment" and operation.result["status"] == "applied"
  end

  defp payment_operation_id(operation) do
    if valid_identifier?(operation["payment_operation_id"]) do
      {:ok, operation["payment_operation_id"]}
    else
      {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp revoke_credit_entitlements(operation, source_id) do
    Repo.all(
      from(entitlement in PaymentCreditEntitlement,
        where: entitlement.cash_payment_source_id == ^source_id,
        order_by: entitlement.id
      )
    )
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(HotelCreditLot, entitlement.hotel_credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.credit_cents)
      shortfall = entitlement.credit_cents - removed

      Repo.update!(
        change(lot,
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents + shortfall
        )
      )

      if credit_active_on_posting_date?(operation, lot) do
        record_credit_movement(operation, "revoked", removed)
        record_credit_availability_movement(operation, lot.id, -removed)
      end
    end)
  end

  defp create_credit_entitlements(cash_allocations, lot_id) do
    {rows, _cash_total} =
      Enum.reduce(cash_allocations, {[], 0}, fn allocation, {rows, cash_total} ->
        next_cash_total = cash_total + allocation.amount_cents
        credit_cents = credit_value(next_cash_total) - credit_value(cash_total)

        rows =
          if credit_cents > 0 do
            [
              %{
                cash_payment_source_id: allocation.source_id,
                hotel_credit_lot_id: lot_id,
                credit_cents: credit_cents
              }
              | rows
            ]
          else
            rows
          end

        {rows, next_cash_total}
      end)

    if rows != [] do
      {count, _} = Repo.insert_all(PaymentCreditEntitlement, Enum.reverse(rows))
      if count != length(rows), do: raise("could not create credit entitlements")
    end
  end

  defp credit_value(cash_cents), do: cash_cents + percentage(cash_cents, 10)

  defp credit_redemptions(guest_id, occurred_on, amount) do
    lots = available_credit_lots(guest_id, occurred_on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, :insufficient_credit}
    else
      {redemptions, _remaining} =
        Enum.reduce(lots, {[], amount}, fn lot, {redemptions, remaining} ->
          redeemed_cents = min(lot.remaining_cents, remaining)
          {[{lot, redeemed_cents} | redemptions], remaining - redeemed_cents}
        end)

      {:ok, Enum.reverse(redemptions) |> Enum.reject(fn {_lot, cents} -> cents == 0 end)}
    end
  end

  defp decrement_credit_lots(redemptions) do
    Enum.reduce_while(redemptions, :ok, fn {lot, amount_cents}, :ok ->
      {count, _} =
        Repo.update_all(
          from(current_lot in HotelCreditLot,
            where: current_lot.id == ^lot.id and current_lot.remaining_cents >= ^amount_cents
          ),
          inc: [remaining_cents: -amount_cents]
        )

      if count == 1, do: {:cont, :ok}, else: {:halt, :error}
    end)
  end

  defp restore_credit_allocations(operation, allocations, occurred_on) do
    Enum.each(allocations, fn allocation ->
      lot = Repo.get!(HotelCreditLot, allocation.lot_id)
      absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)
      restored = allocation.amount_cents - absorbed

      expired? = restored > 0 and Date.compare(lot.expires_on, occurred_on) == :lt

      remaining_cents =
        if restored > 0 and not expired? do
          lot.remaining_cents + restored
        else
          lot.remaining_cents
        end

      Repo.update!(
        change(lot,
          remaining_cents: remaining_cents,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
        )
      )

      record_credit_movement(operation, "absorbed", absorbed)

      if expired? or not credit_active_on_posting_date?(operation, lot) do
        record_credit_movement(operation, "expired", restored)
      else
        record_credit_availability_movement(operation, lot.id, restored)
      end
    end)

    delete_credit_allocations(allocations)
  end

  defp consume_credit_allocations(operation, allocations) do
    record_credit_movement(
      operation,
      "consumed",
      Enum.sum(Enum.map(allocations, & &1.amount_cents))
    )

    delete_credit_allocations(allocations)
  end

  defp delete_credit_allocations(allocations) do
    allocation_ids = Enum.map(allocations, & &1.id)
    Repo.delete_all(from(allocation in CreditAllocation, where: allocation.id in ^allocation_ids))
  end

  defp create_credit_lot(guest_id, source_operation_id, amount_cents, expires_on) do
    Repo.insert!(%HotelCreditLot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      expires_on: expires_on,
      unrecovered_clawback_cents: 0
    })
  end

  defp held_cash_total do
    Repo.aggregate(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: room.status == "active"
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  defp source_total(field), do: Repo.aggregate(CashPaymentSource, :sum, field) || 0

  defp available_credit_total(on) do
    Repo.aggregate(
      from(lot in HotelCreditLot, where: lot.remaining_cents > 0 and lot.expires_on >= ^on),
      :sum,
      :remaining_cents
    ) || 0
  end

  defp applied_credit_total do
    Repo.aggregate(
      from(allocation in CreditAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: room.status == "active"
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  defp credit_shortfall_total do
    Repo.all(
      from(lot in HotelCreditLot,
        left_join: allocation in CreditAllocation,
        on: allocation.hotel_credit_lot_id == lot.id,
        left_join: room in Room,
        on: room.id == allocation.room_id,
        where: lot.unrecovered_clawback_cents > 0,
        group_by: [lot.id, lot.unrecovered_clawback_cents],
        select:
          {lot.unrecovered_clawback_cents,
           coalesce(
             sum(
               fragment(
                 "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                 room.status,
                 allocation.amount_cents
               )
             ),
             0
           )}
      )
    )
    |> Enum.sum_by(fn {unrecovered, applied} -> min(unrecovered, applied) end)
  end

  defp available_credit_lots(guest_id, on) do
    Repo.all(
      from(lot in HotelCreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )
    )
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      "cash" -> :cash
      "hotel_credit" -> :hotel_credit
      _ -> :invalid
    end
  end

  defp cancellation_amounts(true, :cash, cash_paid_cents), do: {cash_paid_cents, 0, 0, 0}

  defp cancellation_amounts(true, :hotel_credit, cash_paid_cents) do
    credit_issued_cents = credit_value(cash_paid_cents)
    {0, 0, cash_paid_cents, credit_issued_cents}
  end

  defp cancellation_amounts(false, :cash, cash_paid_cents), do: {0, cash_paid_cents, 0, 0}

  defp deposit_for(lodging_cents, "flexible"), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for(lodging_cents, "advance_purchase"), do: lodging_cents
  defp percentage(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)

  defp valid_stay(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1, do: :ok, else: :invalid_stay
  end

  defp valid_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp valid_rate_plan(_), do: :invalid_rate_plan
  defp policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  defp refundable_until(_group), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp operation_group_id(operation) do
    if valid_identifier?(operation["group_id"]) do
      {:ok, operation["group_id"]}
    else
      {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp transfer_group_id(operation, key) do
    if valid_identifier?(operation[key]) do
      {:ok, operation[key]}
    else
      {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp common_date(operation) do
    with true <- valid_identifier?(operation["operation_id"]),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      {:ok, occurred_on}
    else
      _ -> {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: :error
  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp equivalent_json?(left, right) when is_map(left) and is_map(right) do
    map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, value} ->
        case Map.fetch(right, key) do
          {:ok, other_value} -> equivalent_json?(value, other_value)
          :error -> false
        end
      end)
  end

  defp equivalent_json?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and
      Enum.zip(left, right)
      |> Enum.all?(fn {left_value, right_value} -> equivalent_json?(left_value, right_value) end)
  end

  defp equivalent_json?(left, right), do: left === right
  defp has_expected_revision?(operation), do: Map.has_key?(operation, "expected_revision")

  defp stale_revision?(operation, group) do
    has_expected_revision?(operation) and operation["expected_revision"] != group.revision
  end

  defp destination_stale_revision?(operation, group) do
    Map.has_key?(operation, "destination_expected_revision") and
      operation["destination_expected_revision"] != group.revision
  end

  defp stale_revision_error(operation, group) do
    rejected(operation, "stale_revision", %{
      group_id: group.group_id,
      expected_revision: operation["expected_revision"],
      actual_revision: group.revision
    })
  end

  defp destination_stale_revision_error(operation, group) do
    rejected(operation, "stale_revision", %{
      group_id: group.group_id,
      expected_revision: operation["destination_expected_revision"],
      actual_revision: group.revision
    })
  end

  defp serialize_group(group) do
    balances = room_balances(group.id)

    totals =
      balances
      |> Enum.filter(&(&1.room.status == "active"))
      |> Enum.reduce(
        %{
          lodging_total_cents: 0,
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0
        },
        fn balance, totals ->
          %{
            lodging_total_cents: totals.lodging_total_cents + balance.room.lodging_total_cents,
            deposit_due_cents: totals.deposit_due_cents + balance.room.deposit_due_cents,
            deposit_paid_cents:
              totals.deposit_paid_cents + balance.cash_paid_cents + balance.credit_paid_cents,
            cash_paid_cents: totals.cash_paid_cents + balance.cash_paid_cents,
            credit_paid_cents: totals.credit_paid_cents + balance.credit_paid_cents
          }
        end
      )

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: date_string(group.booked_on),
      arrival_on: date_string(group.arrival_on),
      departure_on: date_string(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: date_string(refundable_until(group)),
      status: group.status,
      rooms:
        Enum.map(balances, fn balance ->
          %{
            room_id: balance.room.room_id,
            nightly_rate_cents: balance.room.nightly_rate_cents,
            lodging_total_cents: balance.room.lodging_total_cents,
            status: balance.room.status,
            deposit_due_cents: balance.room.deposit_due_cents,
            cash_paid_cents: balance.cash_paid_cents,
            credit_paid_cents: balance.credit_paid_cents
          }
        end),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents
    }
  end

  defp date_string(nil), do: nil
  defp date_string(date), do: Date.to_iso8601(date)

  defp applied(operation, fields),
    do: Map.merge(base_result(operation), Map.put(fields, :status, "applied"))

  defp rejected(operation, code, fields \\ %{}) do
    base_result(operation)
    |> Map.merge(%{status: "rejected", code: code})
    |> Map.merge(fields)
  end

  defp group_error(operation, code, group_id),
    do: rejected(operation, code, %{group_id: group_id})

  defp base_result(operation) do
    case Map.fetch(operation, "operation_id") do
      {:ok, operation_id} -> %{operation_id: operation_id}
      :error -> %{}
    end
  end
end
