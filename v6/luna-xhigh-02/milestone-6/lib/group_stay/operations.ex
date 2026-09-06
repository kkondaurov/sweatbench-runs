defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.CashPayment
  alias GroupStay.CashPaymentDisposition
  alias GroupStay.CreditAllocation
  alias GroupStay.CreditLot
  alias GroupStay.CreditLotContribution
  alias GroupStay.FinanceEvent
  alias GroupStay.FinanceReporting
  alias GroupStay.FinanceReportingCreditOpening
  alias GroupStay.FinanceReportingOpening
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Ledger
  alias GroupStay.OperationRecord
  alias GroupStay.Repo
  alias GroupStay.RoomFundingAllocation

  @group_operation_types ~w(
    record_cash_payment
    apply_hotel_credit
    reschedule_group
    cancel_group
    cancel_rooms
  )
  @policy_cutover ~D[2027-01-01]

  def process(operation) when is_map(operation) do
    operation_id = value(operation, "operation_id")

    if valid_identifier?(operation_id) do
      process_durably(operation, operation_id, canonical_payload(operation))
    else
      rejection(operation_id, "invalid_operation")
    end
  end

  def process(_operation), do: rejection(nil, "invalid_operation")

  def get(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> :not_found
      record -> {:ok, restore_result(record.result)}
    end
  end

  def payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        :not_found

      %{type: "record_cash_payment", result: result} when is_map(result) ->
        if result_value(result, "status") == "applied" do
          case Repo.get(CashPayment, payment_operation_id) do
            nil -> :not_reconcilable
            payment -> {:ok, serialize_payment(payment)}
          end
        else
          :not_reconcilable
        end

      _record ->
        :not_reconcilable
    end
  end

  def payment(_payment_operation_id), do: :not_found

  defp process_durably(operation, operation_id, payload) do
    Repo.transaction(fn ->
      case claim_operation(operation_id, operation, payload) do
        {:new, record} ->
          reporting =
            if value(operation, "type") == "start_finance_reporting",
              do: nil,
              else: Repo.get(FinanceReporting, 1)

          before_finance = if reporting, do: finance_snapshot(), else: nil
          result = process_uncached(operation, operation_id)

          if reporting && result_value(result, "status") == "applied" do
            persist_finance_event!(
              operation,
              result,
              reporting,
              before_finance,
              finance_snapshot()
            )
          end

          persist_result!(record, result)
          result

        {:existing, record} ->
          if record.payload === payload do
            restore_result(record.result)
          else
            rejection(operation_id, "operation_id_conflict")
          end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp claim_operation(operation_id, operation, payload) do
    {count, _rows} =
      Repo.insert_all(
        OperationRecord,
        [
          %{
            operation_id: operation_id,
            type: stored_type(value(operation, "type")),
            payload: payload
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:operation_id]
      )

    record = Repo.get_by!(OperationRecord, operation_id: operation_id)

    if count == 1 do
      {:new, record}
    else
      {:existing, record}
    end
  end

  defp persist_result!(record, result) do
    {:ok, _record} =
      Repo.update(OperationRecord.changeset(record, %{result: canonical_payload(result)}))
  end

  defp restore_result(result) when is_map(result) do
    Map.new(result, fn {key, value} -> {result_key(key), restore_result(value)} end)
  end

  defp restore_result(result) when is_list(result), do: Enum.map(result, &restore_result/1)
  defp restore_result(result), do: result

  defp result_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp process_uncached(operation, operation_id) do
    type = value(operation, "type")

    cond do
      type == "open_group" ->
        process_open(operation, operation_id)

      type == "start_finance_reporting" ->
        process_start_finance_reporting(operation, operation_id)

      type in @group_operation_types ->
        process_group_operation(operation, operation_id, type)

      type == "transfer_deposit" ->
        process_transfer(operation, operation_id)

      type in ["reduce_cash_payment", "charge_back_payment"] ->
        process_payment_operation(operation, operation_id, type)

      true ->
        rejection(operation_id, "invalid_operation")
    end
  end

  defp process_start_finance_reporting(operation, operation_id) do
    with {:ok, starts_on} <- parse_reporting_date(value(operation, "starts_on")) do
      if Repo.get(FinanceReporting, 1) do
        rejection(operation_id, "reporting_already_started")
      else
        start_finance_reporting!(starts_on)

        %{
          operation_id: operation_id,
          status: "applied",
          starts_on: Date.to_iso8601(starts_on)
        }
      end
    else
      {:error, "invalid_reporting_date"} ->
        rejection(operation_id, "invalid_reporting_date")
    end
  end

  defp start_finance_reporting!(starts_on) do
    today = Date.utc_today()
    snapshot = finance_snapshot()

    available_credit =
      snapshot.credit_lots
      |> Enum.reduce(0, fn {_lot_id, lot}, total ->
        if Date.compare(lot.expires_on, today) == :gt,
          do: total + lot.available_cents,
          else: total
      end)

    applied_credit = Map.values(snapshot.credit_applied_by_lot) |> Enum.sum()

    {:ok, _reporting} =
      Repo.insert(
        FinanceReporting.changeset(%FinanceReporting{id: 1}, %{
          id: 1,
          starts_on: starts_on,
          opening_credit_liability_cents: available_credit + applied_credit
        })
      )

    snapshot.held_by_property
    |> Enum.each(fn {property_id, held_cents} ->
      {:ok, _opening} =
        Repo.insert(
          FinanceReportingOpening.changeset(%FinanceReportingOpening{}, %{
            property_id: property_id,
            held_cents: held_cents
          })
        )
    end)

    snapshot.credit_lots
    |> Enum.each(fn {lot_id, lot} ->
      applied_cents = Map.get(snapshot.credit_applied_by_lot, lot_id, 0)

      available_cents =
        if Date.compare(lot.expires_on, today) == :gt, do: lot.available_cents, else: 0

      if available_cents > 0 or applied_cents > 0 do
        {:ok, _opening} =
          Repo.insert(
            FinanceReportingCreditOpening.changeset(%FinanceReportingCreditOpening{}, %{
              lot_id: lot_id,
              source_operation_id: lot.source_operation_id,
              available_cents: available_cents,
              applied_cents: applied_cents,
              expires_on: lot.expires_on
            })
          )
      end
    end)
  end

  defp process_open(operation, operation_id) do
    required = [
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if not present?(operation, required) do
      rejection(operation_id, "invalid_operation")
    else
      group_id = value(operation, "group_id")

      if not valid_identifier?(group_id) or
           not valid_identifier?(value(operation, "guest_id")) or
           not valid_identifier?(value(operation, "property_id")) do
        rejection(operation_id, "invalid_operation", %{group_id: group_id})
      else
        open_group(operation, operation_id, group_id)
      end
    end
  end

  defp open_group(operation, operation_id, group_id) do
    if Repo.get(Group, group_id) do
      rejection(operation_id, "group_already_exists", %{group_id: group_id})
    else
      with {:ok, booked_on} <- parse_date(value(operation, "occurred_on")),
           {:ok, arrival_on} <- parse_date(value(operation, "arrival_on")),
           {:ok, departure_on} <- parse_date(value(operation, "departure_on")),
           :ok <- validate_stay(arrival_on, departure_on),
           {:ok, rate_plan} <- validate_rate_plan(value(operation, "rate_plan")),
           {:ok, rooms} <- validate_rooms(value(operation, "rooms")) do
        nights = Date.diff(departure_on, arrival_on)
        rooms = add_room_amounts(rooms, nights, rate_plan)
        lodging_total = Enum.reduce(rooms, 0, &(&2 + &1.lodging_cents))
        deposit_due = Enum.reduce(rooms, 0, &(&2 + &1.deposit_due_cents))
        policy_version = policy_version(rate_plan, booked_on)
        refundable_until = refundable_until(policy_version, arrival_on)

        group_attrs = %{
          group_id: group_id,
          guest_id: value(operation, "guest_id"),
          property_id: value(operation, "property_id"),
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          policy_version: policy_version,
          refundable_until: refundable_until,
          status: "active",
          revision: 1,
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0
        }

        case Repo.insert(Group.changeset(%Group{}, group_attrs)) do
          {:ok, _group} ->
            room_rows =
              Enum.with_index(rooms, 1)
              |> Enum.map(fn {room, position} ->
                Map.merge(room, %{
                  group_id: group_id,
                  position: position,
                  status: "active",
                  cash_paid_cents: 0,
                  credit_paid_cents: 0
                })
              end)

            Repo.insert_all(Room, room_rows)

            applied(operation_id, %{
              group_id: group_id,
              deposit_due_cents: deposit_due,
              revision: 1
            })

          {:error, _changeset} ->
            rejection(operation_id, "group_already_exists", %{group_id: group_id})
        end
      else
        {:error, code} -> rejection(operation_id, code, %{group_id: group_id})
      end
    end
  end

  defp add_room_amounts(rooms, nights, "advance_purchase") do
    Enum.map(rooms, fn room ->
      lodging = room.nightly_rate_cents * nights
      Map.merge(room, %{lodging_cents: lodging, deposit_due_cents: lodging})
    end)
  end

  defp add_room_amounts(rooms, nights, "flexible") do
    Enum.map(rooms, fn room ->
      lodging = room.nightly_rate_cents * nights

      Map.merge(room, %{
        lodging_cents: lodging,
        deposit_due_cents: round_percentage(lodging, 20, 100)
      })
    end)
  end

  defp process_group_operation(operation, operation_id, type) do
    group_id = value(operation, "group_id")

    if not valid_identifier?(group_id) do
      rejection(operation_id, "invalid_operation")
    else
      case Repo.get(Group, group_id) do
        nil ->
          rejection(operation_id, "group_not_found", %{group_id: group_id})

        group ->
          case check_revision(operation, group) do
            :ok ->
              if group.status != "active" do
                rejection(operation_id, "group_not_active", %{group_id: group_id})
              else
                apply_group_operation(operation, operation_id, type, group)
              end

            {:error, :invalid_operation} ->
              rejection(operation_id, "invalid_operation", %{group_id: group_id})

            {:error, :stale_revision, expected_revision} ->
              rejection(operation_id, "stale_revision", %{
                group_id: group_id,
                expected_revision: expected_revision,
                actual_revision: group.revision
              })
          end
      end
    end
  end

  defp process_transfer(operation, operation_id) do
    source_group_id = value(operation, "source_group_id")
    destination_group_id = value(operation, "destination_group_id")

    if not valid_identifier?(source_group_id) or not valid_identifier?(destination_group_id) do
      rejection(operation_id, "invalid_operation")
    else
      case Repo.get(Group, source_group_id) do
        nil ->
          rejection(operation_id, "group_not_found", %{group_id: source_group_id})

        source_group ->
          case Repo.get(Group, destination_group_id) do
            nil ->
              rejection(operation_id, "group_not_found", %{group_id: destination_group_id})

            destination_group ->
              with :ok <- check_transfer_revision(operation, "expected_revision", source_group),
                   :ok <-
                     check_transfer_revision(
                       operation,
                       "destination_expected_revision",
                       destination_group
                     ) do
                apply_transfer(operation, operation_id, source_group, destination_group)
              else
                {:error, :invalid_operation, group_id} ->
                  rejection(operation_id, "invalid_operation", %{group_id: group_id})

                {:error, :stale_revision, group_id, expected_revision, actual_revision} ->
                  rejection(operation_id, "stale_revision", %{
                    group_id: group_id,
                    expected_revision: expected_revision,
                    actual_revision: actual_revision
                  })
              end
          end
      end
    end
  end

  defp apply_transfer(operation, operation_id, source_group, destination_group) do
    cond do
      source_group.group_id == destination_group.group_id or
          source_group.guest_id != destination_group.guest_id ->
        rejection(operation_id, "invalid_transfer")

      source_group.status != "active" ->
        rejection(operation_id, "group_not_active", %{group_id: source_group.group_id})

      destination_group.status != "active" ->
        rejection(operation_id, "group_not_active", %{group_id: destination_group.group_id})

      not present?(operation, ["amount_cents"]) ->
        rejection(operation_id, "invalid_operation")

      true ->
        case validate_amount(value(operation, "amount_cents")) do
          {:error, code} ->
            rejection(operation_id, code)

          :ok ->
            amount = value(operation, "amount_cents")
            source_held = held_funding(source_group.group_id)
            destination_outstanding = outstanding(destination_group)

            cond do
              amount > source_held ->
                rejection(operation_id, "transfer_exceeds_held_funding")

              amount > destination_outstanding ->
                rejection(operation_id, "transfer_exceeds_outstanding")

              true ->
                transfer_funding!(source_group, destination_group, amount)
                refresh_group!(source_group)
                refresh_group!(destination_group)

                applied(operation_id, %{
                  source_group_id: source_group.group_id,
                  destination_group_id: destination_group.group_id,
                  amount_cents: amount,
                  source_outstanding_deposit_cents: outstanding(source_group),
                  destination_outstanding_deposit_cents: outstanding(destination_group),
                  source_revision: source_group.revision + 1,
                  destination_revision: destination_group.revision + 1
                })
            end
        end
    end
  end

  defp check_transfer_revision(operation, key, group) do
    case fetch(operation, key) do
      :missing ->
        :ok

      {:ok, expected_revision} when is_integer(expected_revision) ->
        if expected_revision == group.revision do
          :ok
        else
          {:error, :stale_revision, group.group_id, expected_revision, group.revision}
        end

      {:ok, _invalid_revision} ->
        {:error, :invalid_operation, group.group_id}
    end
  end

  defp apply_group_operation(operation, operation_id, "record_cash_payment", group) do
    if not present?(operation, ["occurred_on", "amount_cents"]) do
      rejection(operation_id, "invalid_operation", %{group_id: group.group_id})
    else
      with {:ok, _occurred_on} <- parse_date(value(operation, "occurred_on")),
           :ok <- validate_amount(value(operation, "amount_cents")) do
        amount = value(operation, "amount_cents")
        outstanding = outstanding(group)

        if amount > outstanding do
          rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})
        else
          insert_cash_payment!(operation_id, group.group_id, amount)
          allocate_room_funding!(group, "cash_payment", operation_id, nil, amount)
          refresh_group!(group)

          applied(operation_id, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding - amount,
            revision: group.revision + 1
          })
        end
      else
        {:error, code} -> rejection(operation_id, code, %{group_id: group.group_id})
      end
    end
  end

  defp apply_group_operation(operation, operation_id, "apply_hotel_credit", group) do
    if not present?(operation, ["occurred_on", "amount_cents"]) do
      rejection(operation_id, "invalid_operation", %{group_id: group.group_id})
    else
      with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
           :ok <- validate_amount(value(operation, "amount_cents")) do
        amount = value(operation, "amount_cents")
        outstanding = outstanding(group)

        cond do
          amount > outstanding ->
            rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})

          available_credit(group.guest_id, occurred_on) < amount ->
            rejection(operation_id, "insufficient_credit", %{group_id: group.group_id})

          true ->
            allocate_credit!(group, operation_id, amount, occurred_on)
            refresh_group!(group)

            applied(operation_id, %{
              group_id: group.group_id,
              amount_cents: amount,
              outstanding_deposit_cents: outstanding - amount,
              revision: group.revision + 1
            })
        end
      else
        {:error, code} -> rejection(operation_id, code, %{group_id: group.group_id})
      end
    end
  end

  defp apply_group_operation(operation, operation_id, "reschedule_group", group) do
    if not present?(operation, ["occurred_on", "new_arrival_on"]) do
      rejection(operation_id, "invalid_operation", %{group_id: group.group_id})
    else
      with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
           {:ok, new_arrival_on} <- parse_date(value(operation, "new_arrival_on")),
           :ok <- validate_new_stay(occurred_on, new_arrival_on) do
        stay_length = Date.diff(group.departure_on, group.arrival_on)
        new_departure_on = Date.add(new_arrival_on, stay_length)
        policy = policy_for_group(group)
        new_refundable_until = refundable_until(policy, new_arrival_on)

        refresh_group!(group, %{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          policy_version: policy,
          refundable_until: new_refundable_until
        })

        applied(operation_id, %{
          group_id: group.group_id,
          new_arrival_on: Date.to_iso8601(new_arrival_on),
          new_departure_on: Date.to_iso8601(new_departure_on),
          policy_version: policy,
          refundable_until: format_date(new_refundable_until),
          revision: group.revision + 1
        })
      else
        {:error, code} -> rejection(operation_id, code, %{group_id: group.group_id})
      end
    end
  end

  defp apply_group_operation(operation, operation_id, "cancel_group", group) do
    if not present?(operation, ["occurred_on"]) do
      rejection(operation_id, "invalid_operation", %{group_id: group.group_id})
    else
      with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
           {:ok, refund_method} <- refund_method(operation) do
        refundable? = refundable?(group, occurred_on)

        if refund_method == "hotel_credit" and not refundable? do
          rejection(operation_id, "refund_method_not_available", %{group_id: group.group_id})
        else
          positions = active_room_positions(group.group_id)
          cash_before = cash_settled(group.group_id, positions)

          {refunded, retained, credit_issued} =
            settle_rooms!(group, positions, operation_id, occurred_on, refund_method, refundable?)

          set_rooms_cancelled!(group.group_id, positions)
          converted = if refundable? and refund_method == "hotel_credit", do: cash_before, else: 0
          refresh_group!(group, %{status: "cancelled"})

          update_ledger!(
            cash_refunded_cents: refunded,
            cash_retained_cents: retained,
            cash_converted_to_credit_cents: converted
          )

          applied(operation_id, %{
            group_id: group.group_id,
            refunded_cents: refunded,
            retained_cents: retained,
            credit_issued_cents: credit_issued,
            revision: group.revision + 1
          })
        end
      else
        {:error, code} -> rejection(operation_id, code, %{group_id: group.group_id})
      end
    end
  end

  defp apply_group_operation(operation, operation_id, "cancel_rooms", group) do
    if not present?(operation, ["occurred_on", "room_ids"]) do
      rejection(operation_id, "invalid_operation", %{group_id: group.group_id})
    else
      with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
           {:ok, refund_method} <- refund_method(operation),
           {:ok, rooms} <- selected_rooms(group.group_id, value(operation, "room_ids")) do
        refundable? = refundable?(group, occurred_on)

        if refund_method == "hotel_credit" and not refundable? do
          rejection(operation_id, "refund_method_not_available", %{group_id: group.group_id})
        else
          positions = Enum.map(rooms, & &1.position)
          cash_before = cash_settled(group.group_id, positions)

          {refunded, retained, credit_issued} =
            settle_rooms!(group, positions, operation_id, occurred_on, refund_method, refundable?)

          set_rooms_cancelled!(group.group_id, positions)
          remaining_active? = active_room_positions(group.group_id) != []
          status = if remaining_active?, do: "active", else: "cancelled"
          converted = if refundable? and refund_method == "hotel_credit", do: cash_before, else: 0
          refresh_group!(group, %{status: status})

          update_ledger!(
            cash_refunded_cents: refunded,
            cash_retained_cents: retained,
            cash_converted_to_credit_cents: converted
          )

          applied(operation_id, %{
            group_id: group.group_id,
            cancelled_room_ids: Enum.map(rooms, & &1.room_id),
            refunded_cents: refunded,
            retained_cents: retained,
            credit_issued_cents: credit_issued,
            revision: group.revision + 1
          })
        end
      else
        {:error, code} -> rejection(operation_id, code, %{group_id: group.group_id})
      end
    end
  end

  defp process_payment_operation(operation, operation_id, type) do
    payment_operation_id = value(operation, "payment_operation_id")

    if not valid_identifier?(payment_operation_id) do
      rejection(operation_id, "invalid_operation")
    else
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil ->
          rejection(operation_id, "operation_not_found")

        target ->
          group_id = payment_group_id(target)

          if not valid_identifier?(group_id) do
            payment_rejection(operation_id, type)
          else
            case Repo.get(Group, group_id) do
              nil ->
                payment_rejection(operation_id, type)

              group ->
                case check_revision(operation, group) do
                  :ok ->
                    apply_payment_operation(operation, operation_id, type, target, group)

                  {:error, :invalid_operation} ->
                    rejection(operation_id, "invalid_operation", %{group_id: group.group_id})

                  {:error, :stale_revision, expected_revision} ->
                    rejection(operation_id, "stale_revision", %{
                      group_id: group.group_id,
                      expected_revision: expected_revision,
                      actual_revision: group.revision
                    })
                end
            end
          end
      end
    end
  end

  defp apply_payment_operation(operation, operation_id, "reduce_cash_payment", target, group) do
    with :ok <- validate_reduction_amount(operation),
         {:ok, payment} <- reducible_payment(target, group.group_id) do
      amount = value(operation, "amount_cents")

      cond do
        payment.held_cents <= 0 ->
          payment_rejection(operation_id, "reduce_cash_payment", group.group_id)

        amount > payment.held_cents ->
          rejection(operation_id, "reduction_exceeds_held_cash", %{group_id: group.group_id})

        true ->
          changed_group_ids = remove_cash_payment_allocations!(payment, amount)

          update_payment!(payment, %{
            held_cents: payment.held_cents - amount,
            reduced_cents: payment.reduced_cents + amount
          })

          refresh_groups_after_payment!(group, changed_group_ids)
          update_ledger!(cash_reduced_cents: amount)

          applied(operation_id, %{
            payment_operation_id: payment.operation_id,
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(group),
            revision: group.revision + 1
          })
      end
    else
      {:error, code} when is_binary(code) ->
        rejection(operation_id, code, %{group_id: group.group_id})

      {:error, :payment_not_reducible} ->
        payment_rejection(operation_id, "reduce_cash_payment", group.group_id)
    end
  end

  defp apply_payment_operation(_operation, operation_id, "charge_back_payment", target, group) do
    with {:ok, payment} <- chargeable_payment(target, group.group_id) do
      held = payment.held_cents

      chargeback_amount =
        held + payment.refunded_cents + payment.retained_cents +
          payment.converted_to_credit_cents

      changed_group_ids = remove_cash_payment_allocations!(payment, held)
      claw_back_credit_entitlements!(payment.operation_id)

      update_payment!(payment, %{
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: payment.charged_back_cents + chargeback_amount
      })

      clear_payment_dispositions!(payment.operation_id)

      refresh_groups_after_payment!(group, changed_group_ids)

      update_ledger!(
        cash_refunded_cents: -payment.refunded_cents,
        cash_retained_cents: -payment.retained_cents,
        cash_converted_to_credit_cents: -payment.converted_to_credit_cents,
        cash_charged_back_cents: chargeback_amount
      )

      applied(operation_id, %{
        payment_operation_id: payment.operation_id,
        group_id: group.group_id,
        charged_back_cents: chargeback_amount,
        outstanding_deposit_cents: outstanding(group),
        revision: group.revision + 1
      })
    else
      {:error, :payment_not_chargeable} ->
        payment_rejection(operation_id, "charge_back_payment", group.group_id)
    end
  end

  defp payment_rejection(operation_id, type, group_id \\ nil)

  defp payment_rejection(operation_id, "reduce_cash_payment", group_id),
    do: rejection(operation_id, "payment_not_reducible", group_fields(group_id))

  defp payment_rejection(operation_id, "charge_back_payment", group_id),
    do: rejection(operation_id, "payment_not_chargeable", group_fields(group_id))

  defp group_fields(nil), do: %{}
  defp group_fields(group_id), do: %{group_id: group_id}

  defp validate_reduction_amount(operation) do
    if present?(operation, ["amount_cents"]) do
      validate_amount(value(operation, "amount_cents"))
    else
      {:error, "invalid_operation"}
    end
  end

  defp reducible_payment(%OperationRecord{type: "record_cash_payment", result: result}, group_id)
       when is_map(result) do
    if result_value(result, "status") != "applied" do
      {:error, :payment_not_reducible}
    else
      case Repo.get(CashPayment, result_value(result, "operation_id")) do
        %CashPayment{group_id: ^group_id} = payment -> {:ok, payment}
        _payment -> {:error, :payment_not_reducible}
      end
    end
  end

  defp reducible_payment(_target, _group_id), do: {:error, :payment_not_reducible}

  defp chargeable_payment(%OperationRecord{type: "record_cash_payment", result: result}, group_id)
       when is_map(result) do
    if result_value(result, "status") != "applied" do
      {:error, :payment_not_chargeable}
    else
      case Repo.get(CashPayment, result_value(result, "operation_id")) do
        %CashPayment{group_id: ^group_id} = payment ->
          if payment.recorded_cents - payment.reduced_cents - payment.charged_back_cents > 0 do
            {:ok, payment}
          else
            {:error, :payment_not_chargeable}
          end

        _payment ->
          {:error, :payment_not_chargeable}
      end
    end
  end

  defp chargeable_payment(_target, _group_id), do: {:error, :payment_not_chargeable}

  defp payment_group_id(record) do
    result = record.result || %{}
    payload = record.payload || %{}
    result_value(result, "group_id") || result_value(payload, "group_id")
  end

  defp selected_rooms(group_id, room_ids) when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &valid_identifier?/1) and
         length(Enum.uniq(room_ids)) == length(room_ids) do
      rooms =
        Repo.all(
          from room in Room,
            where: room.group_id == ^group_id and room.status == "active",
            order_by: [asc: room.position]
        )

      selected = Enum.filter(rooms, fn room -> room.room_id in room_ids end)

      if length(selected) == length(room_ids),
        do: {:ok, selected},
        else: {:error, "invalid_rooms"}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp selected_rooms(_group_id, _room_ids), do: {:error, "invalid_rooms"}

  defp active_room_positions(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: [asc: room.position],
        select: room.position
    )
  end

  defp settle_rooms!(group, positions, operation_id, occurred_on, refund_method, refundable?) do
    cash_sources = cash_sources(group.group_id, positions)
    cash = Enum.reduce(cash_sources, 0, fn {_source, amount}, total -> total + amount end)
    settle_cash!(group.group_id, positions, cash_sources, refund_method, refundable?)

    credit_sources = credit_sources(group.group_id, positions)

    if refundable? do
      restore_credit!(group.group_id, credit_sources, occurred_on)
    else
      consume_credit!(group.group_id, credit_sources)
    end

    credit_issued =
      if refundable? and refund_method == "hotel_credit" do
        issue_credit!(group.guest_id, operation_id, cash, occurred_on, cash_sources)
      else
        0
      end

    refunded = if refundable? and refund_method == "cash", do: cash, else: 0
    retained = if not refundable?, do: cash, else: 0
    {refunded, retained, credit_issued}
  end

  defp cash_sources(group_id, positions) do
    Repo.all(
      from allocation in RoomFundingAllocation,
        where:
          allocation.group_id == ^group_id and allocation.room_position in ^positions and
            allocation.source_kind in ["legacy_cash", "cash_payment"],
        order_by: [asc: allocation.id]
    )
    |> ordered_sources()
  end

  defp cash_settled(group_id, positions) do
    cash_sources(group_id, positions)
    |> Enum.reduce(0, fn {_source, amount}, total -> total + amount end)
  end

  defp credit_sources(group_id, positions) do
    Repo.all(
      from allocation in RoomFundingAllocation,
        where:
          allocation.group_id == ^group_id and allocation.room_position in ^positions and
            allocation.source_kind == "credit",
        order_by: [asc: allocation.id]
    )
    |> Enum.reduce([], fn allocation, sources ->
      case List.keytake(sources, allocation.credit_lot_id, 0) do
        nil -> sources ++ [{allocation.credit_lot_id, allocation.amount_cents}]
        {{lot_id, amount}, rest} -> rest ++ [{lot_id, amount + allocation.amount_cents}]
      end
    end)
  end

  defp ordered_sources(allocations) do
    Enum.reduce(allocations, [], fn allocation, sources ->
      source = allocation.source_operation_id

      case List.keytake(sources, source, 0) do
        nil -> sources ++ [{source, allocation.amount_cents}]
        {{^source, amount}, rest} -> rest ++ [{source, amount + allocation.amount_cents}]
      end
    end)
  end

  defp settle_cash!(group_id, positions, sources, refund_method, refundable?) do
    property_id = Repo.get!(Group, group_id).property_id

    allocations =
      Repo.all(
        from allocation in RoomFundingAllocation,
          where:
            allocation.group_id == ^group_id and allocation.room_position in ^positions and
              allocation.source_kind in ["legacy_cash", "cash_payment"]
      )

    Enum.each(allocations, fn allocation ->
      Repo.delete!(allocation)
    end)

    bucket =
      cond do
        refundable? and refund_method == "hotel_credit" -> :converted_to_credit_cents
        refundable? -> :refunded_cents
        true -> :retained_cents
      end

    Enum.each(sources, fn {source_operation_id, amount} ->
      if source_operation_id do
        payment = Repo.get!(CashPayment, source_operation_id)

        update_payment!(
          payment,
          Map.put(
            %{held_cents: payment.held_cents - amount},
            bucket,
            Map.get(payment, bucket) + amount
          )
        )

        update_payment_disposition!(payment.operation_id, property_id, bucket, amount)
      end
    end)
  end

  defp restore_credit!(group_id, credit_sources, occurred_on) do
    Enum.each(credit_sources, fn {lot_id, amount} ->
      allocations =
        Repo.all(
          from allocation in RoomFundingAllocation,
            where:
              allocation.group_id == ^group_id and allocation.credit_lot_id == ^lot_id and
                allocation.source_kind == "credit"
        )

      Enum.each(allocations, fn allocation ->
        Repo.delete!(allocation)
      end)

      decrement_credit_allocation!(group_id, lot_id, amount)
      lot = Repo.get!(CreditLot, lot_id)
      return_credit!(lot, amount, occurred_on)
    end)
  end

  defp consume_credit!(group_id, credit_sources) do
    Enum.each(credit_sources, fn {lot_id, amount} ->
      allocations =
        Repo.all(
          from allocation in RoomFundingAllocation,
            where:
              allocation.group_id == ^group_id and allocation.credit_lot_id == ^lot_id and
                allocation.source_kind == "credit"
        )

      Enum.each(allocations, fn allocation ->
        Repo.delete!(allocation)
      end)

      decrement_credit_allocation!(group_id, lot_id, amount)
    end)
  end

  defp issue_credit!(_guest_id, _operation_id, 0, _occurred_on, _sources), do: 0

  defp issue_credit!(guest_id, operation_id, cash, occurred_on, sources) do
    bonus = round_percentage(cash, 10, 100)
    credit_issued = cash + bonus

    {:ok, lot} =
      Repo.insert(
        CreditLot.changeset(%CreditLot{}, %{
          guest_id: guest_id,
          source_operation_id: operation_id,
          remaining_cents: credit_issued,
          expires_on: Date.add(occurred_on, 366),
          unrecovered_clawback_cents: 0
        })
      )

    Enum.reduce(sources, {0, 0}, fn {payment_operation_id, principal},
                                    {previous_cash, previous_value} ->
      current_cash = previous_cash + principal
      current_value = current_cash + round_percentage(current_cash, 10, 100)
      entitlement = current_value - previous_value

      {:ok, _contribution} =
        Repo.insert(
          CreditLotContribution.changeset(%CreditLotContribution{}, %{
            credit_lot_id: lot.id,
            payment_operation_id: payment_operation_id,
            principal_cents: principal,
            entitlement_cents: entitlement
          })
        )

      {current_cash, current_value}
    end)

    credit_issued
  end

  defp allocate_credit!(group, operation_id, amount, occurred_on) do
    lots = available_credit_lots(group.guest_id, occurred_on)

    {remaining, _used} =
      Enum.reduce_while(lots, {amount, []}, fn lot, {remaining, used} ->
        allocation_amount = min(remaining, lot.remaining_cents)

        if allocation_amount > 0 do
          update_lot!(lot, %{remaining_cents: lot.remaining_cents - allocation_amount})
          upsert_credit_allocation!(group.group_id, lot.id, allocation_amount)
          allocate_room_funding!(group, "credit", operation_id, lot.id, allocation_amount)
        end

        if allocation_amount == remaining do
          {:halt, {0, [lot | used]}}
        else
          {:cont, {remaining - allocation_amount, [lot | used]}}
        end
      end)

    if remaining != 0, do: raise("credit allocation became incomplete")
  end

  defp allocate_room_funding!(group, source_kind, source_operation_id, credit_lot_id, amount) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id and room.status == "active",
          order_by: [asc: room.position]
      )

    {remaining, _rooms} =
      Enum.reduce_while(rooms, {amount, []}, fn room, {remaining, updated_rooms} ->
        capacity =
          max(
            (room.deposit_due_cents || 0) - (room.cash_paid_cents || 0) -
              (room.credit_paid_cents || 0),
            0
          )

        allocation_amount = min(remaining, capacity)

        if allocation_amount > 0 do
          {:ok, _allocation} =
            Repo.insert(
              RoomFundingAllocation.changeset(%RoomFundingAllocation{}, %{
                group_id: group.group_id,
                room_position: room.position,
                source_kind: source_kind,
                source_operation_id: source_operation_id,
                credit_lot_id: credit_lot_id,
                amount_cents: allocation_amount
              })
            )

          field = if source_kind == "credit", do: :credit, else: :cash
          update_room_paid!(group.group_id, room.position, field, allocation_amount)
        end

        next_remaining = remaining - allocation_amount

        if next_remaining == 0 do
          {:halt, {0, [room | updated_rooms]}}
        else
          {:cont, {next_remaining, [room | updated_rooms]}}
        end
      end)

    if remaining != 0, do: raise("room funding became incomplete")
  end

  defp held_funding(group_id) do
    positions = active_room_positions(group_id)

    Repo.one(
      from allocation in RoomFundingAllocation,
        where: allocation.group_id == ^group_id and allocation.room_position in ^positions,
        select: coalesce(sum(allocation.amount_cents), 0)
    ) || 0
  end

  defp transfer_funding!(source_group, destination_group, amount) do
    source_positions = active_room_positions(source_group.group_id)

    allocations =
      Repo.all(
        from allocation in RoomFundingAllocation,
          where:
            allocation.group_id == ^source_group.group_id and
              allocation.room_position in ^source_positions,
          order_by: [desc: allocation.id]
      )

    {remaining, _moved} =
      Enum.reduce_while(allocations, {amount, []}, fn allocation, {remaining, moved} ->
        moved_amount = min(remaining, allocation.amount_cents)

        remove_funding_allocation!(allocation, moved_amount)
        allocate_transferred_funding!(destination_group, allocation, moved_amount)

        next_remaining = remaining - moved_amount

        if next_remaining == 0 do
          {:halt, {0, [allocation | moved]}}
        else
          {:cont, {next_remaining, [allocation | moved]}}
        end
      end)

    if remaining != 0, do: raise("deposit transfer became incomplete")
  end

  defp remove_funding_allocation!(allocation, amount) do
    update_room_paid!(
      allocation.group_id,
      allocation.room_position,
      funding_field(allocation),
      -amount
    )

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      update_funding!(allocation, %{amount_cents: allocation.amount_cents - amount})
    end

    if allocation.source_kind == "credit" do
      decrement_credit_allocation!(allocation.group_id, allocation.credit_lot_id, amount)
    end
  end

  defp allocate_transferred_funding!(destination_group, allocation, amount) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^destination_group.group_id and room.status == "active",
          order_by: [asc: room.position]
      )

    {remaining, _rooms} =
      Enum.reduce_while(rooms, {amount, []}, fn room, {remaining, updated_rooms} ->
        capacity =
          max(
            (room.deposit_due_cents || 0) - (room.cash_paid_cents || 0) -
              (room.credit_paid_cents || 0),
            0
          )

        allocation_amount = min(remaining, capacity)

        if allocation_amount > 0 do
          {:ok, _funding} =
            Repo.insert(
              RoomFundingAllocation.changeset(%RoomFundingAllocation{}, %{
                group_id: destination_group.group_id,
                room_position: room.position,
                source_kind: allocation.source_kind,
                source_operation_id: allocation.source_operation_id,
                credit_lot_id: allocation.credit_lot_id,
                amount_cents: allocation_amount
              })
            )

          update_room_paid!(
            destination_group.group_id,
            room.position,
            funding_field(allocation),
            allocation_amount
          )

          if allocation.source_kind == "credit" do
            upsert_credit_allocation!(
              destination_group.group_id,
              allocation.credit_lot_id,
              allocation_amount
            )
          else
            mark_payment_transferred!(allocation.source_operation_id)
          end
        end

        next_remaining = remaining - allocation_amount

        if next_remaining == 0 do
          {:halt, {0, [room | updated_rooms]}}
        else
          {:cont, {next_remaining, [room | updated_rooms]}}
        end
      end)

    if remaining != 0, do: raise("deposit transfer destination became incomplete")
  end

  defp funding_field(%{source_kind: "credit"}), do: :credit
  defp funding_field(_allocation), do: :cash

  defp mark_payment_transferred!(nil), do: :ok

  defp mark_payment_transferred!(operation_id) do
    case Repo.get(CashPayment, operation_id) do
      nil ->
        :ok

      %CashPayment{transfer_participated: true} ->
        :ok

      payment ->
        update_payment!(payment, %{transfer_participated: true})
    end
  end

  defp remove_cash_payment_allocations!(_payment, 0), do: MapSet.new()

  defp remove_cash_payment_allocations!(payment, amount) do
    allocations =
      Repo.all(
        from allocation in RoomFundingAllocation,
          where:
            allocation.source_kind == "cash_payment" and
              allocation.source_operation_id == ^payment.operation_id,
          order_by: [desc: allocation.id]
      )

    {remaining, changed_group_ids} =
      Enum.reduce_while(allocations, {amount, MapSet.new()}, fn allocation,
                                                                {remaining, changed_group_ids} ->
        removed_amount = min(remaining, allocation.amount_cents)
        update_room_paid!(allocation.group_id, allocation.room_position, :cash, -removed_amount)

        if removed_amount == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          update_funding!(allocation, %{amount_cents: allocation.amount_cents - removed_amount})
        end

        next_remaining = remaining - removed_amount
        changed_group_ids = MapSet.put(changed_group_ids, allocation.group_id)

        if next_remaining == 0 do
          {:halt, {0, changed_group_ids}}
        else
          {:cont, {next_remaining, changed_group_ids}}
        end
      end)

    if remaining != 0, do: raise("cash payment allocation became incomplete")
    changed_group_ids
  end

  defp refresh_groups_after_payment!(group, changed_group_ids) do
    changed_group_ids
    |> MapSet.delete(group.group_id)
    |> Enum.each(fn group_id -> refresh_group!(Repo.get!(Group, group_id)) end)

    refresh_group!(group)
  end

  defp claw_back_credit_entitlements!(payment_operation_id) do
    Repo.all(
      from contribution in CreditLotContribution,
        where: contribution.payment_operation_id == ^payment_operation_id
    )
    |> Enum.each(fn contribution ->
      lot = Repo.get!(CreditLot, contribution.credit_lot_id)
      removed = min(lot.remaining_cents, contribution.entitlement_cents)

      update_lot!(lot, %{
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + contribution.entitlement_cents - removed
      })
    end)
  end

  defp return_credit!(lot, amount, occurred_on) do
    absorbed = min(amount, lot.unrecovered_clawback_cents)
    excess = amount - absorbed

    available_add =
      if Date.compare(occurred_on, lot.expires_on) == :lt do
        excess
      else
        0
      end

    update_lot!(lot, %{
      remaining_cents: lot.remaining_cents + available_add,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
    })
  end

  defp upsert_credit_allocation!(group_id, credit_lot_id, amount) do
    case Repo.get_by(CreditAllocation, group_id: group_id, credit_lot_id: credit_lot_id) do
      nil ->
        {:ok, _allocation} =
          Repo.insert(
            CreditAllocation.changeset(%CreditAllocation{}, %{
              group_id: group_id,
              credit_lot_id: credit_lot_id,
              amount_cents: amount
            })
          )

      allocation ->
        update_credit_allocation!(allocation, %{amount_cents: allocation.amount_cents + amount})
    end
  end

  defp decrement_credit_allocation!(group_id, credit_lot_id, amount) do
    allocation = Repo.get_by!(CreditAllocation, group_id: group_id, credit_lot_id: credit_lot_id)

    if allocation.amount_cents == amount do
      Repo.delete!(allocation)
    else
      update_credit_allocation!(allocation, %{amount_cents: allocation.amount_cents - amount})
    end
  end

  defp update_credit_allocation!(allocation, attrs) do
    {:ok, _allocation} = Repo.update(CreditAllocation.changeset(allocation, attrs))
  end

  defp update_funding!(allocation, attrs) do
    {:ok, _allocation} = Repo.update(RoomFundingAllocation.changeset(allocation, attrs))
  end

  defp update_lot!(lot, attrs) do
    {:ok, _lot} = Repo.update(CreditLot.changeset(lot, attrs))
  end

  defp update_room_paid!(group_id, position, field, amount) do
    field = if field == :cash, do: :cash_paid_cents, else: :credit_paid_cents

    {1, _} =
      Repo.update_all(
        from(room in Room,
          where: room.group_id == ^group_id and room.position == ^position,
          update: [inc: [{^field, ^amount}]]
        ),
        []
      )
  end

  defp set_rooms_cancelled!(group_id, positions) do
    Repo.update_all(
      from(room in Room,
        where: room.group_id == ^group_id and room.position in ^positions,
        update: [set: [status: "cancelled"]]
      ),
      []
    )
  end

  defp insert_cash_payment!(operation_id, group_id, amount) do
    {:ok, _payment} =
      Repo.insert(
        CashPayment.changeset(%CashPayment{}, %{
          operation_id: operation_id,
          group_id: group_id,
          recorded_cents: amount,
          held_cents: amount,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 0,
          charged_back_cents: 0,
          transfer_participated: false
        })
      )
  end

  defp update_payment!(payment, attrs) do
    {:ok, _payment} = Repo.update(CashPayment.changeset(payment, attrs))
  end

  defp update_payment_disposition!(payment_operation_id, property_id, bucket, amount) do
    attrs = %{
      payment_operation_id: payment_operation_id,
      property_id: property_id,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0
    }

    disposition =
      Repo.get_by(CashPaymentDisposition,
        payment_operation_id: payment_operation_id,
        property_id: property_id
      ) || begin_payment_disposition!(attrs)

    field =
      case bucket do
        :refunded_cents -> :refunded_cents
        :retained_cents -> :retained_cents
        :converted_to_credit_cents -> :converted_to_credit_cents
      end

    {:ok, _disposition} =
      Repo.update(
        CashPaymentDisposition.changeset(disposition, %{
          field => Map.get(disposition, field) + amount
        })
      )
  end

  defp begin_payment_disposition!(attrs) do
    {:ok, disposition} =
      Repo.insert(CashPaymentDisposition.changeset(%CashPaymentDisposition{}, attrs))

    disposition
  end

  defp clear_payment_dispositions!(payment_operation_id) do
    Repo.update_all(
      from(disposition in CashPaymentDisposition,
        where: disposition.payment_operation_id == ^payment_operation_id,
        update: [set: [refunded_cents: 0, retained_cents: 0, converted_to_credit_cents: 0]]
      ),
      []
    )
  end

  defp refresh_group!(group, attrs \\ %{}) do
    totals = room_totals(group.group_id)
    attrs = Map.merge(totals, attrs) |> Map.put(:revision, group.revision + 1)
    {:ok, _group} = Repo.update(Group.changeset(group, attrs))
  end

  defp room_totals(group_id) do
    Repo.all(from room in Room, where: room.group_id == ^group_id)
    |> Enum.reduce(
      %{
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      },
      fn room, totals ->
        if room.status == "active" do
          cash = room.cash_paid_cents || 0
          credit = room.credit_paid_cents || 0

          %{
            lodging_total_cents: totals.lodging_total_cents + (room.lodging_cents || 0),
            deposit_due_cents: totals.deposit_due_cents + (room.deposit_due_cents || 0),
            deposit_paid_cents: totals.deposit_paid_cents + cash + credit,
            cash_paid_cents: totals.cash_paid_cents + cash,
            credit_paid_cents: totals.credit_paid_cents + credit
          }
        else
          totals
        end
      end
    )
  end

  defp outstanding(group) do
    totals = room_totals(group.group_id)
    max(totals.deposit_due_cents - totals.deposit_paid_cents, 0)
  end

  defp available_credit(guest_id, as_of) do
    available_credit_lots(guest_id, as_of)
    |> Enum.reduce(0, fn lot, total -> total + lot.remaining_cents end)
  end

  defp available_credit_lots(guest_id, as_of) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on > ^as_of,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp update_ledger!(deltas) do
    deltas = Map.new(deltas)

    defaults = %{
      cash_refunded_cents: 0,
      cash_retained_cents: 0,
      cash_converted_to_credit_cents: 0,
      cash_reduced_cents: 0,
      cash_charged_back_cents: 0
    }

    case Repo.get(Ledger, 1) do
      nil ->
        {:ok, _ledger} =
          Repo.insert(Ledger.changeset(%Ledger{id: 1}, Map.merge(defaults, deltas)))

      ledger ->
        attrs =
          Enum.reduce(Map.keys(defaults), %{}, fn field, attrs ->
            Map.put(attrs, field, Map.get(ledger, field, 0) + Map.get(deltas, field, 0))
          end)

        {:ok, _ledger} = Repo.update(Ledger.changeset(ledger, attrs))
    end
  end

  defp persist_finance_event!(operation, result, reporting, before, after_state) do
    {:ok, posting_on} = reporting_posting_date(operation, reporting.starts_on)
    type = value(operation, "type")

    lot_changes =
      credit_lot_changes(
        before.credit_lots,
        after_state.credit_lots,
        before.credit_applied_by_lot,
        after_state.credit_applied_by_lot
      )

    {:ok, _event} =
      Repo.insert(
        FinanceEvent.changeset(%FinanceEvent{}, %{
          operation_id: value(operation, "operation_id"),
          posting_on: posting_on,
          cash_movements: finance_cash_movements(type, operation, result, before, after_state),
          credit_movements:
            finance_credit_movements(type, operation, result, before, after_state, lot_changes),
          credit_lot_changes: lot_changes
        })
      )
  end

  defp reporting_posting_date(operation, starts_on) do
    case parse_reporting_date(value(operation, "occurred_on")) do
      {:ok, occurred_on} -> {:ok, max_date(occurred_on, starts_on)}
      {:error, _reason} -> {:ok, starts_on}
    end
  end

  defp max_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp finance_cash_movements("record_cash_payment", _operation, result, _before, _after) do
    with group_id when is_binary(group_id) <- result_value(result, "group_id"),
         amount when is_integer(amount) <- result_value(result, "amount_cents"),
         %Group{property_id: property_id} <- Repo.get(Group, group_id) do
      cash_movement(%{}, property_id, "received_cents", amount)
    else
      _ -> %{}
    end
  end

  defp finance_cash_movements("transfer_deposit", operation, result, _before, _after) do
    amount = result_value(result, "amount_cents") || 0
    source_property = property_for_group(value(operation, "source_group_id"))
    destination_property = property_for_group(value(operation, "destination_group_id"))

    %{}
    |> cash_movement(source_property, "transferred_out_cents", amount)
    |> cash_movement(destination_property, "transferred_in_cents", amount)
  end

  defp finance_cash_movements(type, operation, result, before, after_state)
       when type in ["cancel_group", "cancel_rooms"] do
    group_id = result_value(result, "group_id")
    property_id = property_for_group(group_id)

    converted =
      if value(operation, "refund_method") == "hotel_credit" do
        max(
          Map.get(before.held_by_group, group_id, 0) -
            Map.get(after_state.held_by_group, group_id, 0),
          0
        )
      else
        0
      end

    %{}
    |> cash_movement(property_id, "refunded_cents", result_value(result, "refunded_cents") || 0)
    |> cash_movement(property_id, "retained_cents", result_value(result, "retained_cents") || 0)
    |> cash_movement(property_id, "converted_to_credit_cents", converted)
  end

  defp finance_cash_movements("reduce_cash_payment", operation, _result, before, after_state) do
    payment_operation_id = value(operation, "payment_operation_id")

    before.held_by_payment_property
    |> Map.get(payment_operation_id, %{})
    |> Map.keys()
    |> Kernel.++(
      Map.get(after_state.held_by_payment_property, payment_operation_id, %{})
      |> Map.keys()
    )
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn property_id, movements ->
      removed =
        max(
          Map.get(
            before.held_by_payment_property |> Map.get(payment_operation_id, %{}),
            property_id,
            0
          ) -
            Map.get(
              after_state.held_by_payment_property |> Map.get(payment_operation_id, %{}),
              property_id,
              0
            ),
          0
        )

      cash_movement(movements, property_id, "reduced_cents", removed)
    end)
  end

  defp finance_cash_movements("charge_back_payment", operation, _result, before, after_state) do
    payment_operation_id = value(operation, "payment_operation_id")
    before_held = Map.get(before.held_by_payment_property, payment_operation_id, %{})
    after_held = Map.get(after_state.held_by_payment_property, payment_operation_id, %{})
    before_dispositions = Map.get(before.dispositions, payment_operation_id, %{})
    after_dispositions = Map.get(after_state.dispositions, payment_operation_id, %{})

    Map.keys(before_held)
    |> Kernel.++(Map.keys(after_held))
    |> Kernel.++(Map.keys(before_dispositions))
    |> Kernel.++(Map.keys(after_dispositions))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn property_id, movements ->
      held_removed =
        max(Map.get(before_held, property_id, 0) - Map.get(after_held, property_id, 0), 0)

      before_disposition = Map.get(before_dispositions, property_id, %{})
      after_disposition = Map.get(after_dispositions, property_id, %{})

      refunded_delta = disposition_delta(before_disposition, after_disposition, "refunded_cents")
      retained_delta = disposition_delta(before_disposition, after_disposition, "retained_cents")

      converted_delta =
        disposition_delta(before_disposition, after_disposition, "converted_to_credit_cents")

      charged_back =
        held_removed - min(refunded_delta, 0) - min(retained_delta, 0) - min(converted_delta, 0)

      movements
      |> cash_movement(property_id, "refunded_cents", refunded_delta)
      |> cash_movement(property_id, "retained_cents", retained_delta)
      |> cash_movement(property_id, "converted_to_credit_cents", converted_delta)
      |> cash_movement(property_id, "charged_back_cents", charged_back)
    end)
  end

  defp finance_cash_movements(_type, _operation, _result, _before, _after), do: %{}

  defp finance_credit_movements(type, operation, result, before, after_state, lot_changes)
       when type in ["cancel_group", "cancel_rooms"] do
    group_id = result_value(result, "group_id")

    removed =
      max(
        Map.get(before.credit_applied_by_group, group_id, 0) -
          Map.get(after_state.credit_applied_by_group, group_id, 0),
        0
      )

    absorbed =
      lot_changes
      |> Map.values()
      |> Enum.reduce(0, fn change, total ->
        total + max(-Map.get(change, "unrecovered_delta", 0), 0)
      end)

    restored =
      lot_changes
      |> Map.values()
      |> Enum.reduce(0, fn change, total ->
        total + max(Map.get(change, "available_delta", 0), 0)
      end)

    movements =
      %{}
      |> credit_movement("issued_cents", result_value(result, "credit_issued_cents") || 0)
      |> credit_movement("absorbed_cents", absorbed)

    non_refundable? =
      case {Repo.get(Group, group_id), parse_date(value(operation, "occurred_on"))} do
        {%Group{} = group, {:ok, occurred_on}} -> not refundable?(group, occurred_on)
        _ -> result_value(result, "retained_cents") > 0
      end

    if non_refundable? do
      credit_movement(movements, "consumed_cents", removed)
    else
      expired = max(removed - absorbed - restored, 0)
      credit_movement(movements, "expired_cents", expired)
    end
  end

  defp finance_credit_movements(
         "charge_back_payment",
         _operation,
         _result,
         _before,
         _after,
         lot_changes
       ) do
    revoked =
      lot_changes
      |> Map.values()
      |> Enum.reduce(0, fn change, total ->
        total + max(-Map.get(change, "available_delta", 0), 0)
      end)

    credit_movement(%{}, "revoked_cents", revoked)
  end

  defp finance_credit_movements(_type, _operation, _result, _before, _after, _lot_changes),
    do: %{}

  defp cash_movement(movements, _property_id, _field, amount) when amount == 0, do: movements

  defp cash_movement(movements, property_id, field, amount) when is_binary(property_id) do
    property_movements = Map.get(movements, property_id, %{})
    Map.put(movements, property_id, Map.update(property_movements, field, amount, &(&1 + amount)))
  end

  defp cash_movement(movements, _property_id, _field, _amount), do: movements

  defp credit_movement(movements, _field, 0), do: movements

  defp credit_movement(movements, field, amount),
    do: Map.update(movements, field, amount, &(&1 + amount))

  defp disposition_delta(before, after_state, field),
    do: Map.get(after_state, field, 0) - Map.get(before, field, 0)

  defp property_for_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      %Group{property_id: property_id} -> property_id
      _ -> nil
    end
  end

  defp property_for_group(_group_id), do: nil

  defp credit_lot_changes(before_lots, after_lots, before_applied, after_applied) do
    (Map.keys(before_lots) ++ Map.keys(after_lots))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn lot_id, changes ->
      before = Map.get(before_lots, lot_id)
      after_state = Map.get(after_lots, lot_id)

      available_delta =
        ((after_state && after_state.available_cents) || 0) -
          ((before && before.available_cents) || 0)

      applied_delta = Map.get(after_applied, lot_id, 0) - Map.get(before_applied, lot_id, 0)

      unrecovered_delta =
        ((after_state && after_state.unrecovered_cents) || 0) -
          ((before && before.unrecovered_cents) || 0)

      if (available_delta == 0 and applied_delta == 0 and unrecovered_delta == 0 and before) &&
           after_state do
        changes
      else
        lot = after_state || before

        Map.put(changes, to_string(lot_id), %{
          "available_delta" => available_delta,
          "applied_delta" => applied_delta,
          "unrecovered_delta" => unrecovered_delta,
          "expires_on" => Date.to_iso8601(lot.expires_on),
          "source_operation_id" => lot.source_operation_id
        })
      end
    end)
  end

  defp finance_snapshot do
    %{
      held_by_property: grouped_cash("property_id"),
      held_by_group: grouped_cash("group_id"),
      held_by_payment_property: grouped_payment_cash(),
      dispositions: payment_dispositions(),
      credit_applied_by_group: credit_applied_by_group(),
      credit_applied_by_lot: credit_applied_by_lot(),
      credit_lots: credit_lots()
    }
  end

  defp grouped_cash(grouping) do
    Repo.all(
      from allocation in RoomFundingAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        join: room in Room,
        on: room.group_id == allocation.group_id and room.position == allocation.room_position,
        where:
          group.status == "active" and room.status == "active" and
            allocation.source_kind in ["legacy_cash", "cash_payment"],
        group_by: [group.property_id, group.group_id],
        select: {group.property_id, group.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.reduce(%{}, fn {property_id, group_id, amount}, totals ->
      key = if grouping == "property_id", do: property_id, else: group_id
      Map.update(totals, key, amount || 0, &(&1 + (amount || 0)))
    end)
  end

  defp grouped_payment_cash do
    Repo.all(
      from allocation in RoomFundingAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        join: room in Room,
        on: room.group_id == allocation.group_id and room.position == allocation.room_position,
        where:
          group.status == "active" and room.status == "active" and
            allocation.source_kind == "cash_payment",
        group_by: [allocation.source_operation_id, group.property_id],
        select: {allocation.source_operation_id, group.property_id, sum(allocation.amount_cents)}
    )
    |> Enum.reduce(%{}, fn {payment_id, property_id, amount}, payments ->
      Map.update(
        payments,
        payment_id,
        %{property_id => amount || 0},
        &Map.put(&1, property_id, amount || 0)
      )
    end)
  end

  defp payment_dispositions do
    Repo.all(from disposition in CashPaymentDisposition, select: disposition)
    |> Enum.reduce(%{}, fn disposition, payments ->
      properties = Map.get(payments, disposition.payment_operation_id, %{})

      Map.put(
        payments,
        disposition.payment_operation_id,
        Map.put(properties, disposition.property_id, %{
          "refunded_cents" => disposition.refunded_cents || 0,
          "retained_cents" => disposition.retained_cents || 0,
          "converted_to_credit_cents" => disposition.converted_to_credit_cents || 0
        })
      )
    end)
  end

  defp credit_applied_by_group do
    Repo.all(
      from allocation in CreditAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        where: group.status == "active",
        group_by: allocation.group_id,
        select: {allocation.group_id, sum(allocation.amount_cents)}
    )
    |> Map.new(fn {group_id, amount} -> {group_id, amount || 0} end)
  end

  defp credit_applied_by_lot do
    Repo.all(
      from allocation in CreditAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        where: group.status == "active",
        group_by: allocation.credit_lot_id,
        select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
    )
    |> Map.new(fn {lot_id, amount} -> {lot_id, amount || 0} end)
  end

  defp credit_lots do
    Repo.all(from lot in CreditLot, select: lot)
    |> Map.new(fn lot ->
      {lot.id,
       %{
         available_cents: lot.remaining_cents || 0,
         unrecovered_cents: lot.unrecovered_clawback_cents || 0,
         expires_on: lot.expires_on,
         source_operation_id: lot.source_operation_id
       }}
    end)
  end

  defp serialize_payment(payment) do
    statement = %{
      payment_operation_id: payment.operation_id,
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
      Map.put(statement, :held_by_group, held_cash_by_group(payment.operation_id))
    else
      statement
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in RoomFundingAllocation,
        where:
          allocation.source_kind == "cash_payment" and
            allocation.source_operation_id == ^payment_operation_id,
        group_by: allocation.group_id,
        order_by: [asc: allocation.group_id],
        select: {allocation.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.map(fn {group_id, amount} -> %{group_id: group_id, amount_cents: amount} end)
  end

  defp round_percentage(amount, numerator, denominator) do
    div(amount * numerator + div(denominator, 2), denominator)
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(arrival_on, departure_on) == :lt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_new_stay(occurred_on, new_arrival_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"],
    do: {:ok, rate_plan}

  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_amount), do: {:error, "invalid_amount"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    Enum.reduce_while(rooms, {:ok, MapSet.new(), []}, fn room, {:ok, ids, valid_rooms} ->
      room_id = value(room, "room_id")
      nightly_rate = value(room, "nightly_rate_cents")

      cond do
        not is_map(room) or not valid_identifier?(room_id) ->
          {:halt, {:error, "invalid_rooms"}}

        not is_integer(nightly_rate) or nightly_rate <= 0 ->
          {:halt, {:error, "invalid_rooms"}}

        MapSet.member?(ids, room_id) ->
          {:halt, {:error, "invalid_rooms"}}

        true ->
          {:cont,
           {:ok, MapSet.put(ids, room_id),
            [%{room_id: room_id, nightly_rate_cents: nightly_rate} | valid_rooms]}}
      end
    end)
    |> case do
      {:ok, _ids, rooms} -> {:ok, Enum.reverse(rooms)}
      {:error, code} -> {:error, code}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp parse_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_date), do: {:error, "invalid_stay"}

  defp parse_reporting_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, "invalid_reporting_date"}
    end
  end

  defp parse_reporting_date(_date), do: {:error, "invalid_reporting_date"}

  defp check_revision(operation, group) do
    case fetch(operation, "expected_revision") do
      :missing ->
        :ok

      {:ok, expected_revision} when is_integer(expected_revision) ->
        if expected_revision == group.revision do
          :ok
        else
          {:error, :stale_revision, expected_revision}
        end

      {:ok, _invalid_revision} ->
        {:error, :invalid_operation}
    end
  end

  defp refund_method(operation) do
    case fetch(operation, "refund_method") do
      :missing -> {:ok, "cash"}
      {:ok, method} when method in ["cash", "hotel_credit"] -> {:ok, method}
      {:ok, _method} -> {:error, "invalid_operation"}
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until_for_group(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp policy_for_group(group),
    do: group.policy_version || policy_version(group.rate_plan, group.booked_on)

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until_for_group(group) do
    group.refundable_until || refundable_until(policy_for_group(group), group.arrival_on)
  end

  defp refundable_until("advance-nonrefundable", _arrival_on), do: nil
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until(_policy, arrival_on), do: Date.add(arrival_on, -14)

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp rejection(operation_id, code, fields \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)
  end

  defp present?(operation, keys) do
    Enum.all?(keys, fn key -> fetch(operation, key) != :missing end)
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp stored_type(type) when is_binary(type), do: type
  defp stored_type(_type), do: nil

  defp canonical_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp value(map, key) when is_map(map) do
    case fetch(map, key) do
      {:ok, value} -> value
      :missing -> nil
    end
  end

  defp value(_map, _key), do: nil

  defp result_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom_key = String.to_existing_atom(key)
        Map.get(map, atom_key)
    end
  rescue
    ArgumentError -> nil
  end

  defp result_value(_map, _key), do: nil

  defp fetch(map, key) do
    atom_key = String.to_existing_atom(key)

    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Map.fetch(map, atom_key) do
          {:ok, value} -> {:ok, value}
          :error -> :missing
        end
    end
  rescue
    ArgumentError -> :missing
  end
end
