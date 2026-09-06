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
    FinanceEvent,
    FinanceReportPublication,
    FinanceReporting,
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
  @cash_movement_fields [
    :received_cents,
    :transferred_in_cents,
    :transferred_out_cents,
    :refunded_cents,
    :retained_cents,
    :converted_to_credit_cents,
    :reduced_cents,
    :charged_back_cents
  ]
  @credit_movement_fields [
    :issued_cents,
    :expired_cents,
    :consumed_cents,
    :revoked_cents,
    :absorbed_cents
  ]

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

  @spec daily_finance_report(term()) ::
          {:ok, map()}
          | {:error, :invalid_reporting_date | :report_not_available}
  def daily_finance_report(date) do
    with {:ok, report_date} <- required_reporting_date(date),
         %FinanceReporting{} = reporting <- Repo.get(FinanceReporting, 1),
         false <- Date.compare(report_date, reporting.starts_on) == :lt do
      case Repo.get(FinanceReportPublication, report_date) do
        nil -> {:ok, build_daily_report(reporting, report_date)}
        publication -> {:ok, Jason.decode!(publication.data_json)}
      end
    else
      {:error, :invalid_reporting_date} -> {:error, :invalid_reporting_date}
      nil -> {:error, :report_not_available}
      true -> {:error, :report_not_available}
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

  defp process_untracked_operation(operation, operation_id, "transfer_deposit"),
    do: process_transfer(operation, operation_id)

  defp process_untracked_operation(operation, operation_id, "start_finance_reporting"),
    do: process_start_finance_reporting(operation, operation_id)

  defp process_untracked_operation(operation, operation_id, "close_finance_period"),
    do: process_close_finance_period(operation, operation_id)

  defp process_untracked_operation(operation, operation_id, operation_type),
    do: process_existing_group(operation, operation_id, operation_type)

  defp process_durable_operation(operation, operation_id, operation_type) do
    payload_json = canonical_json(operation)

    case Repo.transaction(
           fn ->
             case Repo.get_by(OperationRecord, operation_id: operation_id) do
               nil ->
                 case apply_operation_with_finance_tracking(
                        operation,
                        operation_id,
                        operation_type
                      ) do
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

  defp apply_operation(operation, operation_id, "start_finance_reporting"),
    do: apply_start_finance_reporting(operation, operation_id)

  defp apply_operation(operation, operation_id, "close_finance_period"),
    do: apply_close_finance_period(operation, operation_id)

  defp apply_operation(operation, operation_id, operation_type)
       when operation_type in @target_operation_types,
       do: apply_target_operation(operation, operation_id, operation_type)

  defp apply_operation(operation, operation_id, "transfer_deposit"),
    do: apply_transfer(operation, operation_id)

  defp apply_operation(operation, operation_id, operation_type),
    do: apply_existing_group(operation, operation_id, operation_type)

  defp apply_operation_with_finance_tracking(operation, operation_id, operation_type) do
    before =
      if operation_type in ["start_finance_reporting", "close_finance_period"] do
        nil
      else
        if finance_reporting_started?(), do: finance_snapshot(), else: nil
      end

    result = apply_operation(operation, operation_id, operation_type)

    case {before, result, operation_type} do
      {%{} = snapshot, {:ok, applied_result}, operation_type}
      when operation_type not in ["start_finance_reporting", "close_finance_period"] ->
        record_finance_event!(operation, operation_id, operation_type, snapshot, applied_result)
        {:ok, applied_result}

      _ ->
        result
    end
  end

  defp apply_start_finance_reporting(operation, operation_id) do
    with {:ok, starts_on} <- required_reporting_date(value(operation, "starts_on")) do
      case Repo.get(FinanceReporting, 1) do
        %FinanceReporting{} ->
          reject(rejection(operation_id, "reporting_already_started"))

        nil ->
          snapshot = finance_snapshot()

          Repo.insert!(%FinanceReporting{
            id: 1,
            starts_on: starts_on,
            opening_cash_json: Jason.encode!(opening_cash(snapshot)),
            opening_cash_details_json: Jason.encode!(opening_cash_details(snapshot)),
            opening_credit_cents: opening_credit_liability(snapshot, starts_on),
            opening_credit_lots_json: Jason.encode!(opening_credit_lots(snapshot, starts_on))
          })

          {:ok,
           applied("start_finance_reporting", operation_id, %{
             starts_on: Date.to_iso8601(starts_on)
           })}
      end
    else
      {:error, :invalid_reporting_date} ->
        reject(rejection(operation_id, "invalid_reporting_date"))
    end
  end

  defp process_open_group(operation, operation_id) do
    group_id = value(operation, "group_id")

    cond do
      not identifier?(operation_id) ->
        rejection(operation_id, "invalid_operation")

      not identifier?(group_id) ->
        rejection(operation_id, "invalid_operation")

      true ->
        transaction_result(fn ->
          apply_operation_with_finance_tracking(operation, operation_id, "open_group")
        end)
    end
  end

  defp process_start_finance_reporting(operation, operation_id) do
    if identifier?(operation_id) do
      transaction_result(fn ->
        apply_operation_with_finance_tracking(operation, operation_id, "start_finance_reporting")
      end)
    else
      rejection(operation_id, "invalid_operation")
    end
  end

  defp process_close_finance_period(operation, operation_id) do
    if identifier?(operation_id) do
      transaction_result(fn ->
        apply_operation_with_finance_tracking(operation, operation_id, "close_finance_period")
      end)
    else
      rejection(operation_id, "invalid_operation")
    end
  end

  defp apply_close_finance_period(operation, operation_id) do
    with {:ok, period_end_on} <- required_reporting_date(value(operation, "period_end_on")),
         %FinanceReporting{} = reporting <- Repo.get(FinanceReporting, 1),
         true <- Date.compare(period_end_on, reporting.starts_on) != :lt,
         true <- close_after_latest?(period_end_on, reporting.latest_close_on) do
      publish_finance_reports!(reporting, period_end_on)

      reporting
      |> change(latest_close_on: period_end_on)
      |> Repo.update!()

      {:ok,
       applied("close_finance_period", operation_id, %{
         period_end_on: Date.to_iso8601(period_end_on)
       })}
    else
      _ -> reject(rejection(operation_id, "invalid_period"))
    end
  end

  defp close_after_latest?(_period_end_on, nil), do: true

  defp close_after_latest?(period_end_on, latest_close_on),
    do: Date.compare(period_end_on, latest_close_on) == :gt

  defp publish_finance_reports!(reporting, period_end_on) do
    publication_start_on =
      case reporting.latest_close_on do
        nil -> reporting.starts_on
        latest_close_on -> Date.add(latest_close_on, 1)
      end

    publication_start_on
    |> Date.range(period_end_on)
    |> Enum.each(fn report_date ->
      report = build_daily_report(reporting, report_date) |> Map.put("status", "closed")

      Repo.insert!(%FinanceReportPublication{
        report_date: report_date,
        data_json: Jason.encode!(report)
      })
    end)
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
    if operation_type == "transfer_deposit" do
      process_transfer(operation, operation_id)
    else
      process_existing_group_operation(operation, operation_id, operation_type)
    end
  end

  defp process_existing_group_operation(operation, operation_id, operation_type) do
    if operation_type in @target_operation_types do
      if identifier?(value(operation, "payment_operation_id")) do
        transaction_result(fn ->
          apply_operation_with_finance_tracking(operation, operation_id, operation_type)
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
          apply_operation_with_finance_tracking(operation, operation_id, operation_type)
        end)
      end
    end
  end

  defp process_transfer(operation, operation_id) do
    source_group_id = value(operation, "source_group_id")
    destination_group_id = value(operation, "destination_group_id")

    cond do
      not identifier?(operation_id) ->
        rejection(operation_id, "invalid_operation")

      not identifier?(source_group_id) or not identifier?(destination_group_id) ->
        rejection(operation_id, "invalid_operation")

      true ->
        transaction_result(fn ->
          apply_operation_with_finance_tracking(operation, operation_id, "transfer_deposit")
        end)
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

  defp apply_transfer(operation, operation_id) do
    source_group_id = value(operation, "source_group_id")
    destination_group_id = value(operation, "destination_group_id")

    if not identifier?(source_group_id) or not identifier?(destination_group_id) do
      reject(rejection(operation_id, "invalid_operation"))
    else
      case Repo.get(Group, source_group_id) do
        nil ->
          reject(rejection(operation_id, "group_not_found", %{group_id: source_group_id}))

        source_group ->
          case Repo.get(Group, destination_group_id) do
            nil ->
              reject(
                rejection(operation_id, "group_not_found", %{group_id: destination_group_id})
              )

            destination_group ->
              with :ok <- revision_check_for_group(operation, source_group, operation_id),
                   :ok <-
                     revision_check_for_key(
                       operation,
                       destination_group,
                       operation_id,
                       "destination_expected_revision"
                     ) do
                transfer_after_preconditions(
                  source_group,
                  destination_group,
                  operation,
                  operation_id
                )
              else
                {:error, stale} -> reject(stale)
              end
          end
      end
    end
  end

  defp transfer_after_preconditions(source_group, destination_group, operation, operation_id) do
    cond do
      source_group.group_id == destination_group.group_id or
          source_group.guest_id != destination_group.guest_id ->
        reject(rejection(operation_id, "invalid_transfer"))

      source_group.status != @active ->
        reject(rejection(operation_id, "group_not_active", %{group_id: source_group.group_id}))

      destination_group.status != @active ->
        reject(
          rejection(operation_id, "group_not_active", %{group_id: destination_group.group_id})
        )

      true ->
        transfer_with_active_groups(source_group, destination_group, operation, operation_id)
    end
  end

  defp transfer_with_active_groups(source_group, destination_group, operation, operation_id) do
    case operation_date(operation) do
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation"))

      {:error, "invalid_stay"} ->
        reject(rejection(operation_id, "invalid_stay"))

      {:ok, _occurred_on} ->
        amount_cents = value(operation, "amount_cents")
        held_funding = transfer_held_funding(source_group)
        outstanding = transfer_outstanding_deposit(destination_group)

        cond do
          not usable_amount?(amount_cents) ->
            reject(rejection(operation_id, "invalid_amount"))

          amount_cents > held_funding ->
            reject(rejection(operation_id, "transfer_exceeds_held_funding"))

          amount_cents > outstanding ->
            reject(rejection(operation_id, "transfer_exceeds_outstanding"))

          true ->
            ensure_room_accounting!(source_group)
            ensure_room_accounting!(destination_group)
            source_allocations = active_allocations(source_group.group_id)

            execute_transfer(
              source_group,
              destination_group,
              source_allocations,
              amount_cents,
              operation_id
            )
        end
    end
  end

  defp transfer_held_funding(%Group{room_accounting_initialized: true} = group) do
    group.group_id
    |> active_allocations()
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  defp transfer_held_funding(group),
    do: integer_value(group.cash_paid_cents) + integer_value(group.credit_paid_cents)

  defp transfer_outstanding_deposit(%Group{room_accounting_initialized: true} = group),
    do: outstanding_deposit(group)

  defp transfer_outstanding_deposit(group),
    do:
      max(
        integer_value(group.deposit_due_cents) - integer_value(group.deposit_paid_cents),
        0
      )

  defp execute_transfer(
         source_group,
         destination_group,
         source_allocations,
         amount_cents,
         operation_id
       ) do
    moved = take_allocations(source_allocations, amount_cents)
    destination_rooms = active_rooms(destination_group)

    {room_chunks, _updated_rooms} =
      allocate_amount_to_rooms(destination_rooms, amount_cents, :cash_paid_cents)

    transfer_chunks = pair_transfer_chunks(room_chunks, moved)

    Enum.each(moved, fn %{amount_cents: amount} = moved_allocation ->
      remove_allocation_amount!(moved_allocation, amount)
    end)

    update_destination_rooms!(destination_rooms, transfer_chunks)
    insert_transferred_allocations!(destination_group.group_id, transfer_chunks)
    mark_transferred_payments!(transfer_chunks)

    update_group_with_totals!(source_group, %{revision: source_group.revision + 1})
    update_group_with_totals!(destination_group, %{revision: destination_group.revision + 1})

    {:ok,
     applied("transfer_deposit", operation_id, %{
       source_group_id: source_group.group_id,
       destination_group_id: destination_group.group_id,
       amount_cents: amount_cents,
       source_outstanding_deposit_cents: outstanding_deposit(source_group),
       destination_outstanding_deposit_cents: outstanding_deposit(destination_group),
       source_revision: source_group.revision + 1,
       destination_revision: destination_group.revision + 1
     })}
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
          charged_back_cents: 0,
          transfer_participated: false
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
          affected_groups = remove_cash_for_payment!(payment.payment_operation_id, amount_cents)

          payment
          |> change(
            held_cents: held - amount_cents,
            reduced_cents: payment.reduced_cents + amount_cents
          )
          |> Repo.update!()

          update_groups_after_funding_change!(
            group,
            Map.keys(affected_groups),
            %{cash_reduced_cents: integer_value(group.cash_reduced_cents) + amount_cents}
          )

          updated_group = Repo.get!(Group, group.group_id)

          {:ok,
           applied("reduce_cash_payment", operation_id, %{
             payment_operation_id: payment.payment_operation_id,
             group_id: group.group_id,
             amount_cents: amount_cents,
             outstanding_deposit_cents: outstanding_deposit(updated_group),
             revision: updated_group.revision
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
        affected_groups =
          remove_cash_for_payment!(payment.payment_operation_id, payment.held_cents)

        revoke_credit_entitlements!(payment.payment_operation_id)

        update_group_after_chargeback!(
          group,
          payment,
          charged_back_cents,
          Map.keys(affected_groups)
        )

        updated_group = Repo.get!(Group, group.group_id)

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
           outstanding_deposit_cents: outstanding_deposit(updated_group),
           revision: updated_group.revision
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
    revision_check_for_key(operation, group, operation_id, "expected_revision")
  end

  defp revision_check_for_key(operation, group, operation_id, key) do
    case present_value(operation, key) do
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
    sequences = next_allocation_sequences!(length(chunks))

    rows =
      Enum.zip(chunks, sequences)
      |> Enum.map(fn {{room_id, amount}, allocation_sequence} ->
        %{
          group_id: group_id,
          room_id: room_id,
          payment_operation_id: operation_id,
          amount_cents: amount,
          allocation_sequence: allocation_sequence
        }
      end)

    if rows != [], do: Repo.insert_all(CashAllocation, rows)
  end

  defp insert_cash_allocation_rows!(group_id, rows) do
    sequences = next_allocation_sequences!(length(rows))

    rows =
      Enum.zip(rows, sequences)
      |> Enum.map(fn {{operation_id, room_id, amount}, allocation_sequence} ->
        %{
          group_id: group_id,
          room_id: room_id,
          payment_operation_id: operation_id,
          amount_cents: amount,
          allocation_sequence: allocation_sequence
        }
      end)

    if rows != [], do: Repo.insert_all(CashAllocation, rows)
  end

  defp insert_credit_allocations!(group_id, operation_id, chunks) do
    sequences = next_allocation_sequences!(length(chunks))

    rows =
      Enum.zip(chunks, sequences)
      |> Enum.map(fn {{lot, room_id, amount}, allocation_sequence} ->
        %{
          group_id: group_id,
          room_id: room_id,
          credit_lot_id: lot.id,
          operation_id: operation_id,
          amount_cents: amount,
          allocation_sequence: allocation_sequence
        }
      end)

    if rows != [], do: Repo.insert_all(HotelCreditAllocation, rows)
  end

  defp insert_credit_allocation_rows!(group_id, rows) do
    sequences = next_allocation_sequences!(length(rows))

    rows =
      Enum.zip(rows, sequences)
      |> Enum.map(fn {{lot_id, operation_id, room_id, amount}, allocation_sequence} ->
        %{
          group_id: group_id,
          credit_lot_id: lot_id,
          room_id: room_id,
          operation_id: operation_id,
          amount_cents: amount,
          allocation_sequence: allocation_sequence
        }
      end)

    if rows != [], do: Repo.insert_all(HotelCreditAllocation, rows)
  end

  defp active_allocations(group_id) do
    cash_rows =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and room.status == ^@active and
              allocation.amount_cents > 0,
          select: allocation
      )
      |> Enum.map(fn allocation ->
        %{
          allocation: allocation,
          funding_type: :cash,
          source_operation_id: allocation.payment_operation_id,
          amount_cents: allocation.amount_cents,
          room_id: allocation.room_id,
          allocation_sequence: allocation.allocation_sequence
        }
      end)

    credit_rows =
      Repo.all(
        from allocation in HotelCreditAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and room.status == ^@active and
              allocation.amount_cents > 0,
          select: allocation
      )
      |> Enum.map(fn allocation ->
        %{
          allocation: allocation,
          funding_type: :credit,
          source_operation_id: allocation.operation_id,
          amount_cents: allocation.amount_cents,
          room_id: allocation.room_id,
          allocation_sequence: allocation.allocation_sequence
        }
      end)

    rows = cash_rows ++ credit_rows
    order = operation_order(Enum.map(rows, & &1.source_operation_id) |> Enum.reject(&is_nil/1))
    Enum.sort_by(rows, &allocation_sort_key(&1, order), :desc)
  end

  defp allocation_sort_key(allocation, operation_order) do
    case allocation.allocation_sequence do
      sequence when is_integer(sequence) ->
        {1, sequence, allocation.allocation.id}

      _ ->
        {0, Map.get(operation_order, allocation.source_operation_id, 0), allocation.allocation.id}
    end
  end

  defp take_allocations(rows, amount_cents), do: take_allocations(rows, amount_cents, [])

  defp take_allocations([], 0, moved), do: Enum.reverse(moved)

  defp take_allocations([row | rest], remaining, moved) do
    amount = min(row.amount_cents, remaining)

    take_allocations(
      rest,
      remaining - amount,
      [%{row | amount_cents: amount} | moved]
    )
  end

  defp pair_transfer_chunks(room_chunks, moved), do: pair_transfer_chunks(room_chunks, moved, [])

  defp pair_transfer_chunks([], _moved, result), do: Enum.reverse(result)
  defp pair_transfer_chunks(_rooms, [], result), do: Enum.reverse(result)

  defp pair_transfer_chunks(
         [{room_id, room_amount} | rooms],
         [%{amount_cents: moved_amount} = moved | rest],
         result
       ) do
    amount = min(room_amount, moved_amount)
    chunk = moved |> Map.put(:room_id, room_id) |> Map.put(:amount_cents, amount)
    result = [chunk | result]

    cond do
      room_amount == moved_amount ->
        pair_transfer_chunks(rooms, rest, result)

      room_amount < moved_amount ->
        pair_transfer_chunks(
          rooms,
          [%{moved | amount_cents: moved_amount - amount} | rest],
          result
        )

      true ->
        pair_transfer_chunks(
          [{room_id, room_amount - amount} | rooms],
          rest,
          result
        )
    end
  end

  defp remove_allocation_amount!(%{funding_type: funding_type, allocation: allocation}, amount) do
    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()
    end

    room = Repo.get_by!(Room, group_id: allocation.group_id, room_id: allocation.room_id)
    field_name = if funding_type == :cash, do: :cash_paid_cents, else: :credit_paid_cents

    room
    |> change(%{field_name => integer_value(Map.get(room, field_name)) - amount})
    |> Repo.update!()
  end

  defp update_destination_rooms!(rooms, transfer_chunks) do
    update_rooms_from_chunks!(
      rooms,
      for(
        %{funding_type: :cash, room_id: room_id, amount_cents: amount} <- transfer_chunks,
        do: {room_id, amount}
      ),
      :cash_paid_cents
    )

    update_rooms_from_chunks!(
      rooms,
      for(
        %{funding_type: :credit, room_id: room_id, amount_cents: amount} <- transfer_chunks,
        do: {room_id, amount}
      ),
      :credit_paid_cents
    )
  end

  defp insert_transferred_allocations!(group_id, transfer_chunks) do
    sequences = next_allocation_sequences!(length(transfer_chunks))

    {cash_rows, credit_rows} =
      Enum.zip(transfer_chunks, sequences)
      |> Enum.reduce({[], []}, fn
        {%{funding_type: :cash, allocation: allocation, room_id: room_id, amount_cents: amount},
         sequence},
        {cash, credit} ->
          {[
             %{
               group_id: group_id,
               room_id: room_id,
               payment_operation_id: allocation.payment_operation_id,
               amount_cents: amount,
               allocation_sequence: sequence
             }
             | cash
           ], credit}

        {%{funding_type: :credit, allocation: allocation, room_id: room_id, amount_cents: amount},
         sequence},
        {cash, credit} ->
          {cash,
           [
             %{
               group_id: group_id,
               room_id: room_id,
               credit_lot_id: allocation.credit_lot_id,
               operation_id: allocation.operation_id,
               amount_cents: amount,
               allocation_sequence: sequence
             }
             | credit
           ]}
      end)

    if cash_rows != [], do: Repo.insert_all(CashAllocation, Enum.reverse(cash_rows))
    if credit_rows != [], do: Repo.insert_all(HotelCreditAllocation, Enum.reverse(credit_rows))
  end

  defp mark_transferred_payments!(transfer_chunks) do
    payment_ids =
      transfer_chunks
      |> Enum.filter(&(&1.funding_type == :cash))
      |> Enum.map(& &1.allocation.payment_operation_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if payment_ids != [] do
      Repo.update_all(
        from(payment in CashPayment, where: payment.payment_operation_id in ^payment_ids),
        set: [transfer_participated: true]
      )
    end
  end

  defp next_allocation_sequences!(0), do: []

  defp next_allocation_sequences!(count) do
    cash_max =
      Repo.one(
        from allocation in CashAllocation,
          select: coalesce(max(allocation.allocation_sequence), 0)
      )

    credit_max =
      Repo.one(
        from allocation in HotelCreditAllocation,
          select: coalesce(max(allocation.allocation_sequence), 0)
      )

    first = max(integer_value(cash_max), integer_value(credit_max)) + 1
    Enum.to_list(first..(first + count - 1))
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
      sort_key =
        allocations
        |> Enum.map(&cash_allocation_sort_key(&1, order))
        |> Enum.min()

      {operation_id, Enum.sum(Enum.map(allocations, & &1.amount_cents)), sort_key}
    end)
    |> Enum.sort_by(fn {_operation_id, _amount, sort_key} -> sort_key end)
    |> Enum.map(fn {operation_id, amount, _sort_key} -> {operation_id, amount} end)
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

  defp cash_allocation_sort_key(%{payment_operation_id: nil}, _order), do: {0, 0, 0}

  defp cash_allocation_sort_key(allocation, order) do
    case allocation.allocation_sequence do
      sequence when is_integer(sequence) -> {1, sequence, allocation.id}
      _ -> {1, Map.get(order, allocation.payment_operation_id, 0), allocation.id}
    end
  end

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

  defp remove_cash_for_payment!(_payment_operation_id, 0), do: %{}

  defp remove_cash_for_payment!(payment_operation_id, amount_cents) do
    rows =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.payment_operation_id == ^payment_operation_id and
              room.status == ^@active and allocation.amount_cents > 0,
          select: allocation
      )

    order = operation_order([payment_operation_id])

    {remaining, affected_groups} =
      rows
      |> Enum.sort_by(
        fn allocation ->
          allocation_sort_key(
            %{
              allocation: allocation,
              source_operation_id: allocation.payment_operation_id,
              allocation_sequence: allocation.allocation_sequence
            },
            order
          )
        end,
        :desc
      )
      |> Enum.reduce({amount_cents, %{}}, fn allocation, {remaining, affected_groups} ->
        take = min(remaining, allocation.amount_cents)

        if take > 0 do
          if take == allocation.amount_cents,
            do: Repo.delete!(allocation),
            else:
              allocation |> change(amount_cents: allocation.amount_cents - take) |> Repo.update!()

          room = Repo.get_by!(Room, group_id: allocation.group_id, room_id: allocation.room_id)

          room
          |> change(cash_paid_cents: integer_value(room.cash_paid_cents) - take)
          |> Repo.update!()

          affected_groups =
            Map.update(affected_groups, allocation.group_id, take, &(&1 + take))

          {remaining - take, affected_groups}
        else
          {remaining, affected_groups}
        end
      end)

    if remaining > 0, do: raise("cash allocation invariant violated")
    affected_groups
  end

  defp update_groups_after_funding_change!(addressed_group, affected_group_ids, addressed_attrs) do
    group_ids = Enum.uniq([addressed_group.group_id | affected_group_ids])

    Enum.each(group_ids, fn group_id ->
      group = Repo.get!(Group, group_id)
      attrs = if group_id == addressed_group.group_id, do: addressed_attrs, else: %{}
      update_group_with_totals!(group, Map.put(attrs, :revision, group.revision + 1))
    end)
  end

  defp update_group_after_chargeback!(group, payment, charged_back_cents, affected_group_ids) do
    update_groups_after_funding_change!(
      group,
      affected_group_ids,
      %{
        refunded_cents: max(integer_value(group.refunded_cents) - payment.refunded_cents, 0),
        retained_cents: max(integer_value(group.retained_cents) - payment.retained_cents, 0),
        cash_converted_to_credit_cents:
          max(
            integer_value(group.cash_converted_to_credit_cents) -
              payment.converted_to_credit_cents,
            0
          ),
        cash_charged_back_cents: integer_value(group.cash_charged_back_cents) + charged_back_cents
      }
    )
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
    view = %{
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

    if payment.transfer_participated do
      Map.put(view, :held_by_group, held_cash_by_group(payment.payment_operation_id))
    else
      view
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        join: room in Room,
        on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            room.status == ^@active,
        group_by: allocation.group_id,
        select: {allocation.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {group_id, amount} -> %{group_id: group_id, amount_cents: amount} end)
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

  defp build_daily_report(reporting, report_date) do
    events =
      Repo.all(
        from event in FinanceEvent,
          where: event.posting_on >= ^reporting.starts_on and event.posting_on <= ^report_date,
          order_by: event.id
      )

    opening_cash = Jason.decode!(reporting.opening_cash_json)
    cash_through = cash_event_totals(events)
    today_events = Enum.filter(events, &same_date?(&1.posting_on, report_date))

    {ordinary_today_events, late_today_events} =
      Enum.split_with(today_events, fn event -> not late_event?(event) end)

    cash_today = cash_event_totals(ordinary_today_events)
    late_cash_today = cash_event_totals(late_today_events)

    properties =
      (Map.keys(opening_cash) ++
         Map.keys(cash_through) ++
         Map.keys(cash_today) ++
         Map.keys(late_cash_today))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(&cash_report_entry(&1, opening_cash, cash_through, cash_today))
      |> Enum.reject(fn entry ->
        zero_cash_report_entry?(entry) and
          zero_cash_movement_values?(Map.get(late_cash_today, entry["property_id"], %{}))
      end)

    credit_through =
      events
      |> credit_event_totals()
      |> merge_credit_movements(expiry_movements(reporting, report_date, events, false))

    credit_today =
      ordinary_today_events
      |> credit_event_totals()
      |> merge_credit_movements(expiry_movements(reporting, report_date, events, true))

    late_credit_today = credit_event_totals(late_today_events)

    late_adjustments = %{
      "cash" =>
        late_cash_today
        |> Map.keys()
        |> Enum.sort()
        |> Enum.map(fn property_id ->
          %{
            "property_id" => property_id,
            "movements" => cash_movement_view(Map.get(late_cash_today, property_id, %{}))
          }
        end)
        |> Enum.reject(fn entry ->
          Enum.all?(Map.values(entry["movements"]), &(&1 == 0))
        end),
      "credit" => credit_movement_view(late_credit_today)
    }

    credit = %{
      "opening_liability_cents" => reporting.opening_credit_cents,
      "movements" => credit_movement_view(credit_today),
      "closing_liability_cents" =>
        reporting.opening_credit_cents + credit_balance_change(credit_through)
    }

    %{
      "date" => Date.to_iso8601(report_date),
      "status" => "open",
      "cash" => cash,
      "credit" => credit,
      "late_adjustments" => late_adjustments
    }
  end

  defp late_event?(event) do
    natural_posting_on = event.natural_posting_on || event.posting_on
    Date.compare(event.posting_on, natural_posting_on) == :gt
  end

  defp cash_report_entry(property_id, opening_cash, through, today) do
    opening = integer_value(Map.get(opening_cash, property_id, 0))
    through_values = Map.get(through, property_id, %{})
    today_values = Map.get(today, property_id, %{})
    closing = opening + cash_balance_change(through_values)

    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => cash_movement_view(today_values),
      "closing_held_cents" => closing
    }
  end

  defp zero_cash_report_entry?(entry) do
    entry["opening_held_cents"] == 0 and entry["closing_held_cents"] == 0 and
      zero_cash_movement_values?(entry["movements"])
  end

  defp zero_cash_movement_values?(values) do
    Enum.all?(@cash_movement_fields, fn field ->
      integer_value(Map.get(values, field, Map.get(values, Atom.to_string(field), 0))) == 0
    end)
  end

  defp cash_event_totals(events) do
    Enum.reduce(events, %{}, fn event, totals ->
      event.cash_json
      |> Jason.decode!()
      |> Enum.reduce(totals, fn {property_id, values}, totals ->
        Enum.reduce(@cash_movement_fields, totals, fn field, totals ->
          amount = integer_value(map_value(values, Atom.to_string(field)))
          add_cash_effect(totals, property_id, field, amount)
        end)
      end)
    end)
  end

  defp cash_movement_view(values) do
    Map.new(@cash_movement_fields, fn field ->
      {Atom.to_string(field), integer_value(Map.get(values, field, 0))}
    end)
  end

  defp cash_balance_change(values) do
    integer_value(Map.get(values, :received_cents, 0)) +
      integer_value(Map.get(values, :transferred_in_cents, 0)) -
      integer_value(Map.get(values, :transferred_out_cents, 0)) -
      integer_value(Map.get(values, :refunded_cents, 0)) -
      integer_value(Map.get(values, :retained_cents, 0)) -
      integer_value(Map.get(values, :converted_to_credit_cents, 0)) -
      integer_value(Map.get(values, :reduced_cents, 0)) -
      integer_value(Map.get(values, :charged_back_cents, 0))
  end

  defp credit_event_totals(events) do
    Enum.reduce(events, %{}, fn event, totals ->
      event.credit_json
      |> Jason.decode!()
      |> Enum.reduce(totals, fn {field, amount}, totals ->
        atom_field = String.to_existing_atom(field)
        add_credit_effect(totals, atom_field, integer_value(amount))
      end)
    end)
  end

  defp merge_credit_movements(first, second) do
    Enum.reduce(second, first, fn {field, amount}, totals ->
      add_credit_effect(totals, field, amount)
    end)
  end

  defp credit_movement_view(values) do
    Map.new(@credit_movement_fields, fn field ->
      {Atom.to_string(field), integer_value(Map.get(values, field, 0))}
    end)
  end

  defp credit_balance_change(values) do
    integer_value(Map.get(values, :issued_cents, 0)) -
      integer_value(Map.get(values, :expired_cents, 0)) -
      integer_value(Map.get(values, :consumed_cents, 0)) -
      integer_value(Map.get(values, :revoked_cents, 0)) -
      integer_value(Map.get(values, :absorbed_cents, 0))
  end

  defp expiry_movements(reporting, report_date, events, exact?) do
    opening_lots = Jason.decode!(reporting.opening_credit_lots_json)

    lots =
      Map.new(opening_lots, fn lot ->
        {map_value(lot, "lot_id"),
         %{
           remaining_cents: integer_value(map_value(lot, "remaining_cents")),
           expires_on: map_value(lot, "expires_on")
         }}
      end)

    lots =
      Enum.reduce(events, lots, fn event, lots ->
        Enum.reduce(Jason.decode!(event.credit_lot_deltas_json), lots, fn delta, lots ->
          lot_id = map_value(delta, "lot_id")

          current =
            Map.get(lots, lot_id, %{
              remaining_cents: 0,
              expires_on: map_value(delta, "expires_on")
            })

          Map.put(lots, lot_id, %{
            current
            | expires_on: current.expires_on || map_value(delta, "expires_on")
          })
        end)
      end)

    Enum.reduce(lots, %{}, fn {lot_id, lot}, movements ->
      with {:ok, expires_on} <- Date.from_iso8601(lot.expires_on),
           expiration_date = expires_on,
           true <- Date.compare(expires_on, reporting.starts_on) == :gt,
           true <-
             if(exact?,
               do: Date.compare(expiration_date, report_date) == :eq,
               else: Date.compare(expiration_date, report_date) != :gt
             ) do
        opening_remaining =
          opening_lots
          |> Enum.find_value(0, fn opening_lot ->
            if map_value(opening_lot, "lot_id") == lot_id,
              do: integer_value(map_value(opening_lot, "remaining_cents"))
          end)

        available_at_expiry =
          Enum.reduce(events, opening_remaining, fn event, remaining ->
            if Date.compare(event.posting_on, expires_on) != :gt do
              Enum.reduce(Jason.decode!(event.credit_lot_deltas_json), remaining, fn delta,
                                                                                     remaining ->
                if map_value(delta, "lot_id") == lot_id,
                  do: remaining + integer_value(map_value(delta, "delta_cents")),
                  else: remaining
              end)
            else
              remaining
            end
          end)

        add_credit_effect(movements, :expired_cents, max(available_at_expiry, 0))
      else
        _ -> movements
      end
    end)
  end

  defp same_date?(first, second), do: Date.compare(first, second) == :eq

  defp finance_reporting_started?, do: not is_nil(Repo.get(FinanceReporting, 1))

  defp finance_snapshot do
    Repo.all(Group) |> Enum.each(&ensure_room_accounting!/1)

    groups =
      Repo.all(Group)
      |> Map.new(fn group ->
        {group.group_id,
         %{
           property_id: group.property_id,
           status: group.status,
           policy_version: group_policy_version(group),
           booked_on: group.booked_on,
           arrival_on: group.arrival_on,
           group_id: group.group_id,
           refunded_cents: integer_value(group.refunded_cents),
           retained_cents: integer_value(group.retained_cents),
           converted_to_credit_cents: integer_value(group.cash_converted_to_credit_cents)
         }}
      end)

    cash =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: room.status == ^@active and allocation.amount_cents > 0,
          select: {allocation, group.property_id}
      )
      |> Enum.map(fn {allocation, property_id} ->
        %{
          group_id: allocation.group_id,
          property_id: property_id,
          payment_operation_id: allocation.payment_operation_id,
          amount_cents: allocation.amount_cents,
          allocation_sequence: allocation.allocation_sequence,
          id: allocation.id
        }
      end)

    credit =
      Repo.all(
        from allocation in HotelCreditAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where: room.status == ^@active and allocation.amount_cents > 0,
          select: allocation
      )
      |> Enum.map(fn allocation ->
        %{
          group_id: allocation.group_id,
          credit_lot_id: allocation.credit_lot_id,
          amount_cents: allocation.amount_cents
        }
      end)

    payments =
      Repo.all(CashPayment)
      |> Map.new(fn payment ->
        {payment.payment_operation_id,
         %{
           group_id: payment.group_id,
           recorded_cents: payment.recorded_cents,
           held_cents: payment.held_cents,
           refunded_cents: payment.refunded_cents,
           retained_cents: payment.retained_cents,
           converted_to_credit_cents: payment.converted_to_credit_cents,
           reduced_cents: payment.reduced_cents,
           charged_back_cents: payment.charged_back_cents
         }}
      end)

    lots =
      Repo.all(HotelCreditLot)
      |> Map.new(fn lot ->
        {lot.id,
         %{
           remaining_cents: integer_value(lot.remaining_cents),
           issued_on: lot.issued_on,
           expires_on: lot.expires_on,
           unrecovered_clawback_cents: integer_value(lot.unrecovered_clawback_cents)
         }}
      end)

    %{groups: groups, cash: cash, credit: credit, payments: payments, lots: lots}
  end

  defp opening_cash(snapshot) do
    Enum.reduce(snapshot.cash, %{}, fn row, opening ->
      Map.update(opening, row.property_id, row.amount_cents, &(&1 + row.amount_cents))
    end)
  end

  defp opening_cash_details(snapshot) do
    Enum.reduce(snapshot.payments, %{}, fn {payment_id, payment}, details ->
      settled =
        Enum.reduce(
          [:refunded_cents, :retained_cents, :converted_to_credit_cents],
          %{},
          fn field, values ->
            amount = integer_value(Map.get(payment, field))
            if amount > 0, do: Map.put(values, field, amount), else: values
          end
        )

      if settled == %{} do
        details
      else
        property_id = get_in(snapshot.groups, [payment.group_id, :property_id])
        Map.put(details, payment_id, [Map.put(settled, :property_id, property_id)])
      end
    end)
  end

  defp opening_credit_liability(snapshot, as_of) do
    available =
      snapshot.lots
      |> Enum.map(fn {_lot_id, lot} ->
        if Date.compare(lot.expires_on, as_of) == :gt, do: lot.remaining_cents, else: 0
      end)
      |> Enum.sum()

    applied = Enum.sum(Enum.map(snapshot.credit, & &1.amount_cents))
    available + applied
  end

  defp opening_credit_lots(snapshot, as_of) do
    applied_by_lot =
      Enum.reduce(snapshot.credit, %{}, fn allocation, amounts ->
        Map.update(
          amounts,
          allocation.credit_lot_id,
          allocation.amount_cents,
          &(&1 + allocation.amount_cents)
        )
      end)

    snapshot.lots
    |> Enum.flat_map(fn {lot_id, lot} ->
      available =
        if Date.compare(lot.expires_on, as_of) == :gt do
          lot.remaining_cents
        else
          0
        end

      applied = Map.get(applied_by_lot, lot_id, 0)

      if available + applied > 0 do
        [
          %{
            lot_id: Integer.to_string(lot_id),
            remaining_cents: available,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.lot_id)
  end

  defp required_reporting_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  defp required_reporting_date(_date), do: {:error, :invalid_reporting_date}

  defp record_finance_event!(operation, operation_id, operation_type, before, result) do
    reporting = Repo.get!(FinanceReporting, 1)
    after_snapshot = finance_snapshot()
    effects = finance_effects(operation, operation_type, result, before, after_snapshot)
    {:ok, occurred_on} = operation_date(operation)
    natural_posting_on = later_date(occurred_on, reporting.starts_on)

    posting_on =
      case reporting.latest_close_on do
        nil -> natural_posting_on
        latest_close_on -> later_date(natural_posting_on, Date.add(latest_close_on, 1))
      end

    Repo.insert!(%FinanceEvent{
      operation_id: operation_id,
      operation_type: operation_type,
      natural_posting_on: natural_posting_on,
      posting_on: posting_on,
      cash_json: Jason.encode!(effects.cash),
      credit_json: Jason.encode!(effects.credit),
      cash_details_json: Jason.encode!(effects.cash_details),
      credit_lot_deltas_json: Jason.encode!(effects.credit_lot_deltas)
    })
  end

  defp finance_effects(operation, operation_type, result, before, after_snapshot) do
    {cash, credit, cash_details} =
      case operation_type do
        "record_cash_payment" ->
          group_id = result_value(result, "group_id")
          property_id = get_in(after_snapshot.groups, [group_id, :property_id])

          {add_cash_effect(
             %{},
             property_id,
             :received_cents,
             result_value(result, "amount_cents")
           ), %{}, []}

        "transfer_deposit" ->
          {removed, added} = cash_allocation_changes(before, after_snapshot)

          cash =
            Enum.reduce(removed, %{}, fn {{_group_id, _payment_id, property_id}, amount}, acc ->
              add_cash_effect(acc, property_id, :transferred_out_cents, amount)
            end)

          cash =
            Enum.reduce(added, cash, fn {{_group_id, _payment_id, property_id}, amount}, acc ->
              add_cash_effect(acc, property_id, :transferred_in_cents, amount)
            end)

          {cash, %{}, []}

        operation_type when operation_type in ["cancel_group", "cancel_rooms"] ->
          cancellation_finance_effects(operation, result, before, after_snapshot)

        "reduce_cash_payment" ->
          {removed, _added} = cash_allocation_changes(before, after_snapshot)
          payment_id = value(operation, "payment_operation_id")

          cash =
            Enum.reduce(removed, %{}, fn {{_group_id, current_payment_id, property_id}, amount},
                                         acc ->
              if current_payment_id == payment_id,
                do: add_cash_effect(acc, property_id, :reduced_cents, amount),
                else: acc
            end)

          {cash, %{}, []}

        "charge_back_payment" ->
          {cash, credit} = chargeback_finance_effects(operation, before, after_snapshot)
          {cash, credit, []}

        _ ->
          {%{}, %{}, []}
      end

    %{
      cash: cash,
      credit: credit,
      cash_details: cash_details,
      credit_lot_deltas: credit_lot_deltas(before, after_snapshot)
    }
  end

  defp cancellation_finance_effects(operation, result, before, after_snapshot) do
    {removed, _added} = cash_allocation_changes(before, after_snapshot)
    payment_deltas = payment_deltas(before, after_snapshot)

    {cash, cash_details} =
      Enum.reduce(payment_deltas, {%{}, []}, fn {payment_id, deltas}, {cash, details} ->
        rows = cash_rows_for_payment(removed, payment_id)

        {cash, payment_details} =
          Enum.reduce(
            [:refunded_cents, :retained_cents, :converted_to_credit_cents],
            {cash, []},
            fn field, {cash, details} ->
              amount = Map.get(deltas, field, 0)

              if amount > 0 do
                distributions = distribute_cash_rows(rows, amount)

                {cash, details} =
                  Enum.reduce(distributions, {cash, details}, fn {property_id, distributed},
                                                                 {cash, details} ->
                    cash = add_cash_effect(cash, property_id, field, distributed)

                    details =
                      add_cash_detail(details, payment_id, property_id, field, distributed)

                    {cash, details}
                  end)

                {cash, details}
              else
                {cash, details}
              end
            end
          )

        {cash, details ++ payment_details}
      end)

    group_id = result_value(result, "group_id")
    group = Map.get(before.groups, group_id)

    {cash_with_legacy, cash_details_with_legacy} =
      if group do
        Enum.reduce(
          [:refunded_cents, :retained_cents, :converted_to_credit_cents],
          {cash, cash_details},
          fn field, {cash, details} ->
            before_amount = Map.get(group, field, 0)
            after_group = Map.get(after_snapshot.groups, group_id, %{})
            after_amount = Map.get(after_group, field, before_amount)
            known = Enum.sum(Enum.map(cash_details, &Map.get(&1, field, 0)))
            legacy = max(after_amount - before_amount - known, 0)

            if legacy > 0 do
              {add_cash_effect(cash, group.property_id, field, legacy), details}
            else
              {cash, details}
            end
          end
        )
      else
        {cash, cash_details}
      end

    credit = cancellation_credit_effects(operation, result, before, after_snapshot)
    {cash_with_legacy, credit, cash_details_with_legacy}
  end

  defp cancellation_credit_effects(operation, result, before, after_snapshot) do
    group_id = result_value(result, "group_id")
    group = Map.get(before.groups, group_id)
    {removed, _added} = credit_allocation_changes(before, after_snapshot)
    refundable? = refundable_snapshot?(group, value(operation, "occurred_on"))

    credit =
      Enum.reduce(removed, %{}, fn {{_group_id, lot_id}, amount}, credit ->
        old_lot = Map.get(before.lots, lot_id, %{})
        new_lot = Map.get(after_snapshot.lots, lot_id, old_lot)

        if refundable? do
          absorbed =
            max(
              Map.get(old_lot, :unrecovered_clawback_cents, 0) -
                Map.get(new_lot, :unrecovered_clawback_cents, 0),
              0
            )

          restored =
            max(Map.get(new_lot, :remaining_cents, 0) - Map.get(old_lot, :remaining_cents, 0), 0)

          expired = max(amount - absorbed - restored, 0)

          credit
          |> add_credit_effect(:absorbed_cents, absorbed)
          |> add_credit_effect(:expired_cents, expired)
        else
          add_credit_effect(credit, :consumed_cents, amount)
        end
      end)

    issued = result_value(result, "credit_issued_cents") || 0
    add_credit_effect(credit, :issued_cents, issued)
  end

  defp chargeback_finance_effects(operation, before, after_snapshot) do
    payment_id = value(operation, "payment_operation_id")
    {:ok, occurred_on} = operation_date(operation)
    payment = Map.get(before.payments, payment_id, %{})
    # The held allocations are removed by the operation. Reconstruct them from
    # the pre-operation snapshot separately so their property follows the cash.
    held_rows =
      before.cash
      |> Enum.filter(&(&1.payment_operation_id == payment_id))
      |> Enum.map(&{{&1.group_id, payment_id, &1.property_id}, &1.amount_cents})

    cash =
      Enum.reduce(held_rows, %{}, fn {{_group_id, _payment_id, property_id}, amount}, acc ->
        add_cash_effect(acc, property_id, :charged_back_cents, amount)
      end)

    settlement_details = settlement_details_for_payment(payment_id)

    cash =
      Enum.reduce(settlement_details, cash, fn detail, cash ->
        property_id = map_value(detail, "property_id")

        amounts =
          Enum.map(["refunded_cents", "retained_cents", "converted_to_credit_cents"], fn key ->
            {String.to_existing_atom(key), integer_value(map_value(detail, key))}
          end)

        cash =
          Enum.reduce(amounts, cash, fn {field, amount}, cash ->
            if amount > 0 do
              cash
              |> add_cash_effect(property_id, field, -amount)
              |> add_cash_effect(property_id, :charged_back_cents, amount)
            else
              cash
            end
          end)

        cash
      end)

    fallback_property = get_in(before.groups, [Map.get(payment, :group_id), :property_id])

    cash =
      Enum.reduce(
        [
          {:refunded_cents, Map.get(payment, :refunded_cents, 0)},
          {:retained_cents, Map.get(payment, :retained_cents, 0)},
          {:converted_to_credit_cents, Map.get(payment, :converted_to_credit_cents, 0)}
        ],
        cash,
        fn {field, amount}, cash ->
          known =
            settlement_details
            |> Enum.map(&integer_value(map_value(&1, Atom.to_string(field))))
            |> Enum.sum()

          missing = max(amount - known, 0)

          if missing > 0 do
            cash
            |> add_cash_effect(fallback_property, field, -missing)
            |> add_cash_effect(fallback_property, :charged_back_cents, missing)
          else
            cash
          end
        end
      )

    credit =
      Enum.reduce(before.lots, %{}, fn {lot_id, old_lot}, credit ->
        new_lot = Map.get(after_snapshot.lots, lot_id, old_lot)

        revoked =
          if Date.compare(old_lot.expires_on, occurred_on) == :gt do
            max(old_lot.remaining_cents - new_lot.remaining_cents, 0)
          else
            0
          end

        add_credit_effect(credit, :revoked_cents, revoked)
      end)

    {cash, credit}
  end

  defp settlement_details_for_payment(payment_id) do
    reporting = Repo.get!(FinanceReporting, 1)
    opening = Jason.decode!(reporting.opening_cash_details_json)
    opening_details = Map.get(opening, payment_id, [])

    event_details =
      Repo.all(from event in FinanceEvent, order_by: event.id)
      |> Enum.flat_map(fn event ->
        event.cash_details_json
        |> Jason.decode!()
        |> Enum.filter(&(map_value(&1, "payment_operation_id") == payment_id))
      end)

    opening_details ++ event_details
  end

  defp cash_allocation_changes(before, after_snapshot) do
    before_totals = allocation_totals(before.cash)
    after_totals = allocation_totals(after_snapshot.cash)

    removed =
      Enum.reduce(before_totals, %{}, fn {key, amount}, changes ->
        difference = amount - Map.get(after_totals, key, 0)
        if difference > 0, do: Map.put(changes, key, difference), else: changes
      end)

    added =
      Enum.reduce(after_totals, %{}, fn {key, amount}, changes ->
        difference = amount - Map.get(before_totals, key, 0)
        if difference > 0, do: Map.put(changes, key, difference), else: changes
      end)

    {removed, added}
  end

  defp allocation_totals(rows) do
    Enum.reduce(rows, %{}, fn row, totals ->
      key = {row.group_id, row.payment_operation_id, row.property_id}
      Map.update(totals, key, row.amount_cents, &(&1 + row.amount_cents))
    end)
  end

  defp cash_rows_for_payment(changes, payment_id) do
    changes
    |> Enum.filter(fn {{_group_id, current_payment_id, _property_id}, _amount} ->
      current_payment_id == payment_id
    end)
    |> Enum.map(fn {{_group_id, _payment_id, property_id}, amount} -> {property_id, amount} end)
  end

  defp distribute_cash_rows(rows, amount) do
    {_remaining, distributions} =
      Enum.reduce(rows, {amount, []}, fn {property_id, available}, {remaining, distributions} ->
        taken = min(remaining, available)

        if taken > 0,
          do: {remaining - taken, distributions ++ [{property_id, taken}]},
          else: {remaining, distributions}
      end)

    distributions
  end

  defp payment_deltas(before, after_snapshot) do
    fields = [
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ]

    (Map.keys(before.payments) ++ Map.keys(after_snapshot.payments))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn payment_id, deltas ->
      old = Map.get(before.payments, payment_id, %{})
      new = Map.get(after_snapshot.payments, payment_id, %{})

      payment_delta =
        Enum.reduce(fields, %{}, fn field, values ->
          difference = Map.get(new, field, 0) - Map.get(old, field, 0)
          if difference != 0, do: Map.put(values, field, difference), else: values
        end)

      if payment_delta == %{}, do: deltas, else: Map.put(deltas, payment_id, payment_delta)
    end)
  end

  defp credit_allocation_changes(before, after_snapshot) do
    before_totals = credit_allocation_totals(before.credit)
    after_totals = credit_allocation_totals(after_snapshot.credit)

    removed =
      Enum.reduce(before_totals, %{}, fn {key, amount}, changes ->
        difference = amount - Map.get(after_totals, key, 0)
        if difference > 0, do: Map.put(changes, key, difference), else: changes
      end)

    added =
      Enum.reduce(after_totals, %{}, fn {key, amount}, changes ->
        difference = amount - Map.get(before_totals, key, 0)
        if difference > 0, do: Map.put(changes, key, difference), else: changes
      end)

    {removed, added}
  end

  defp credit_allocation_totals(rows) do
    Enum.reduce(rows, %{}, fn row, totals ->
      key = {row.group_id, row.credit_lot_id}
      Map.update(totals, key, row.amount_cents, &(&1 + row.amount_cents))
    end)
  end

  defp credit_lot_deltas(before, after_snapshot) do
    (Map.keys(before.lots) ++ Map.keys(after_snapshot.lots))
    |> Enum.uniq()
    |> Enum.flat_map(fn lot_id ->
      old = Map.get(before.lots, lot_id, %{})
      new = Map.get(after_snapshot.lots, lot_id, old)
      delta = Map.get(new, :remaining_cents, 0) - Map.get(old, :remaining_cents, 0)

      if delta == 0 do
        []
      else
        [
          %{
            lot_id: Integer.to_string(lot_id),
            delta_cents: delta,
            expires_on: Date.to_iso8601(Map.get(new, :expires_on, Map.get(old, :expires_on)))
          }
        ]
      end
    end)
  end

  defp add_cash_effect(cash, nil, _field, _amount), do: cash
  defp add_cash_effect(cash, _property_id, _field, 0), do: cash

  defp add_cash_effect(cash, property_id, field, amount) do
    Map.update(cash, property_id, %{field => amount}, fn values ->
      Map.update(values, field, amount, &(&1 + amount))
    end)
  end

  defp add_cash_detail(details, payment_id, property_id, field, amount) do
    detail = %{field => amount, payment_operation_id: payment_id, property_id: property_id}

    case Enum.find_index(details, fn existing ->
           existing.payment_operation_id == payment_id and existing.property_id == property_id
         end) do
      nil ->
        details ++ [detail]

      index ->
        List.update_at(
          details,
          index,
          &Map.update(&1, field, amount, fn value -> value + amount end)
        )
    end
  end

  defp add_credit_effect(credit, _field, 0), do: credit

  defp add_credit_effect(credit, field, amount),
    do: Map.update(credit, field, amount, &(&1 + amount))

  defp result_value(result, key), do: map_value(result, key)

  defp map_value(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_binary(key) and Map.has_key?(map, String.to_atom(key)) ->
        Map.get(map, String.to_atom(key))

      true ->
        nil
    end
  end

  defp refundable_snapshot?(nil, _occurred_on), do: false

  defp refundable_snapshot?(group, occurred_on) when is_binary(occurred_on) do
    with {:ok, occurred_on} <- Date.from_iso8601(occurred_on),
         policy when policy in [@flex_14, @flex_30] <- group.policy_version do
      Date.compare(occurred_on, refundable_until(policy, group.arrival_on)) != :gt
    else
      _ -> false
    end
  end

  defp refundable_snapshot?(_group, _occurred_on), do: false

  defp later_date(first, second) do
    if Date.compare(first, second) == :lt, do: second, else: first
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
        charged_back_cents: 0,
        transfer_participated: false
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
        charged_back_cents: 0,
        transfer_participated: false
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
