defmodule GroupStay.Operations do
  import Ecto.Query

  alias Ecto.Changeset

  alias GroupStay.{
    CashAllocation,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    FinanceEvent,
    FinanceOpeningCash,
    FinanceOpeningCredit,
    FinanceReporting,
    Group,
    Operation,
    PaymentAccounting,
    PaymentDisposition,
    Repo,
    Room
  }

  @valid_rate_plans ["flexible", "advance_purchase"]
  @policy_cutover ~D[2027-01-01]
  @valid_policy_versions ["flex-14", "flex-30", "advance-nonrefundable"]
  @valid_refund_methods ["cash", "hotel_credit"]

  def process_batch(params) when is_map(params) do
    operations = field(params, "operations")

    if is_list(operations) do
      {:ok, Enum.map(operations, &process_operation/1)}
    else
      {:error, :invalid_batch}
    end
  end

  def process_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) when is_binary(group_id) do
    case Repo.transaction(fn ->
           case Repo.get(Group, group_id) do
             nil -> nil
             group -> ensure_room_accounting!(group)
           end
         end) do
      {:ok, nil} -> {:error, :group_not_found}
      {:ok, group} -> {:ok, group_payload(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> {:ok, Jason.decode!(operation.result)}
    end
  end

  def get_operation(_operation_id), do: {:error, :operation_not_found}

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      operation ->
        result = Jason.decode!(operation.result)

        if operation.operation_type == "record_cash_payment" and
             result["status"] == "applied" do
          maybe_initialize_payment_group!(result["group_id"])

          case Repo.get(PaymentAccounting, payment_operation_id) do
            nil -> {:error, :payment_not_reconcilable}
            accounting -> {:ok, payment_payload(accounting)}
          end
        else
          {:error, :payment_not_reconcilable}
        end
    end
  end

  def get_payment(_payment_operation_id), do: {:error, :operation_not_found}

  def ledger, do: ledger(nil)

  def ledger(on) do
    with {:ok, as_of} <- parse_as_of(on) do
      initialize_legacy_groups!()

      %{
        "cash_held_cents" => sum_active(:cash_paid_cents),
        "cash_refunded_cents" => sum_all(:refunded_cents),
        "cash_retained_cents" => sum_all(:retained_cents),
        "cash_converted_to_credit_cents" => sum_all(:converted_cents),
        "cash_reduced_cents" => sum_all(:reduced_cents),
        "cash_charged_back_cents" => sum_all(:charged_back_cents),
        "credit_liability_cents" => credit_liability(as_of),
        "credit_shortfall_cents" => credit_shortfall()
      }
    end
  end

  def guest_credit(guest_id), do: guest_credit(guest_id, nil)

  def guest_credit(guest_id, on) when is_binary(guest_id) do
    with {:ok, as_of} <- parse_as_of(on) do
      lots = available_credit_lots(guest_id, as_of)

      {:ok,
       %{
         "guest_id" => guest_id,
         "available_cents" => Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
         "lots" => Enum.map(lots, &credit_lot_payload/1)
       }}
    end
  end

  def guest_credit(_guest_id, _on), do: {:error, :invalid_date}

  def daily_finance_report(date) do
    with {:ok, report_date} <- parse_reporting_date(date),
         %FinanceReporting{} = reporting <- Repo.get(FinanceReporting, 1),
         true <- Date.compare(report_date, reporting.starts_on) != :lt do
      {:ok, build_daily_report(reporting, report_date)}
    else
      nil -> {:error, :report_not_available}
      false -> {:error, :report_not_available}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = field(operation, "operation_id")

    if valid_identifier?(operation_id) do
      process_durable(operation, operation_id)
    else
      process_operation_without_durability(operation)
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_operation_without_durability(operation) do
    operation_id = field(operation, "operation_id")

    case field(operation, "type") do
      "open_group" -> process_open(operation, operation_id)
      "start_finance_reporting" -> process_start_reporting(operation, operation_id)
      "record_cash_payment" -> process_existing(operation, operation_id, :payment)
      "apply_hotel_credit" -> process_existing(operation, operation_id, :credit)
      "reschedule_group" -> process_existing(operation, operation_id, :reschedule)
      "cancel_group" -> process_existing(operation, operation_id, :cancel)
      "cancel_rooms" -> process_existing(operation, operation_id, :cancel_rooms)
      "transfer_deposit" -> process_transfer(operation, operation_id)
      "reduce_cash_payment" -> process_target(operation, operation_id, :reduce)
      "charge_back_payment" -> process_target(operation, operation_id, :chargeback)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp process_durable(operation, operation_id) do
    payload = encode_payload(operation)

    :global.trans({{__MODULE__, :operation}, operation_id}, fn ->
      case Repo.get_by(Operation, operation_id: operation_id) do
        nil -> durable_apply(operation, operation_id, payload)
        record -> replay_or_conflict(record, operation, operation_id)
      end
    end)
  end

  defp durable_apply(operation, operation_id, payload) do
    operation_transaction = fn ->
      durable_apply_in_transaction(operation, operation_id, payload)
    end

    result =
      case operation_lock(operation) do
        nil ->
          {:ok, result} = Repo.transaction(operation_transaction)
          result

        lock_id ->
          transaction(lock_id, operation_transaction)
      end

    result
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint == "operations_operation_id_index" do
        case Repo.get_by(Operation, operation_id: operation_id) do
          nil -> reraise error, __STACKTRACE__
          record -> replay_or_conflict(record, operation, operation_id)
        end
      else
        reraise error, __STACKTRACE__
      end
  end

  defp durable_apply_in_transaction(operation, operation_id, payload) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        record =
          Repo.insert!(%Operation{
            operation_id: operation_id,
            operation_type: operation_type(operation),
            payload: payload,
            result: Jason.encode!(%{})
          })

        result = process_operation_in_transaction(operation)

        record
        |> Changeset.change(result: Jason.encode!(result))
        |> Repo.update!()

        result

      record ->
        replay_or_conflict(record, operation, operation_id)
    end
  end

  defp process_operation_in_transaction(operation) do
    operation_id = field(operation, "operation_id")

    case field(operation, "type") do
      "open_group" ->
        process_open_in_transaction(operation, operation_id)

      "start_finance_reporting" ->
        process_start_reporting_in_transaction(operation, operation_id)

      "record_cash_payment" ->
        process_existing_in_transaction(operation, operation_id, :payment)

      "apply_hotel_credit" ->
        process_existing_in_transaction(operation, operation_id, :credit)

      "reschedule_group" ->
        process_existing_in_transaction(operation, operation_id, :reschedule)

      "cancel_group" ->
        process_existing_in_transaction(operation, operation_id, :cancel)

      "cancel_rooms" ->
        process_existing_in_transaction(operation, operation_id, :cancel_rooms)

      "transfer_deposit" ->
        process_transfer_in_transaction(operation, operation_id)

      "reduce_cash_payment" ->
        process_target_in_transaction(operation, operation_id, :reduce)

      "charge_back_payment" ->
        process_target_in_transaction(operation, operation_id, :chargeback)

      _ ->
        rejected(operation_id, "invalid_operation")
    end
  end

  defp process_open_in_transaction(operation, operation_id) do
    if required_fields?(operation, open_fields()) do
      group_id = field(operation, "group_id")

      if valid_identifier?(group_id) do
        open_group(operation, operation_id, group_id)
      else
        rejected(operation_id, "invalid_operation")
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_start_reporting(operation, operation_id) do
    if valid_identifier?(operation_id) do
      transaction({:finance_reporting, 1}, fn -> start_reporting(operation, operation_id) end)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_start_reporting_in_transaction(operation, operation_id) do
    start_reporting(operation, operation_id)
  end

  defp start_reporting(operation, operation_id) do
    with {:ok, starts_on} <- reporting_date(operation),
         nil <- Repo.get(FinanceReporting, 1) do
      initialize_legacy_groups!()
      capture_reporting_opening!(starts_on)

      applied(operation_id, %{"starts_on" => Date.to_iso8601(starts_on)})
    else
      {:error, _reason} -> rejected(operation_id, "invalid_reporting_date")
      %FinanceReporting{} -> rejected(operation_id, "reporting_already_started")
    end
  end

  defp process_existing_in_transaction(operation, operation_id, kind) do
    group_id = field(operation, "group_id")

    if valid_identifier?(group_id) do
      existing_operation(operation, operation_id, group_id, kind)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_transfer_in_transaction(operation, operation_id) do
    source_group_id = field(operation, "source_group_id")
    destination_group_id = field(operation, "destination_group_id")

    if valid_identifier?(source_group_id) and valid_identifier?(destination_group_id) do
      transfer_operation(operation, operation_id, source_group_id, destination_group_id)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_target_in_transaction(operation, operation_id, kind) do
    payment_operation_id = field(operation, "payment_operation_id")

    if valid_identifier?(payment_operation_id) do
      target_operation(operation, operation_id, payment_operation_id, kind)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp operation_lock(operation) do
    case field(operation, "type") do
      "open_group" ->
        case field(operation, "group_id") do
          group_id when is_binary(group_id) and byte_size(group_id) > 0 -> {:group, group_id}
          _ -> nil
        end

      "start_finance_reporting" ->
        {:finance_reporting, 1}

      type
      when type in [
             "record_cash_payment",
             "apply_hotel_credit",
             "reschedule_group",
             "cancel_group",
             "cancel_rooms"
           ] ->
        group_lock(field(operation, "group_id"))

      "transfer_deposit" ->
        transfer_lock(operation)

      type when type in ["reduce_cash_payment", "charge_back_payment"] ->
        case target_group_id(field(operation, "payment_operation_id")) do
          nil -> {:payment, field(operation, "payment_operation_id")}
          group_id -> group_lock(group_id)
        end

      _ ->
        nil
    end
  end

  defp group_lock(group_id) when is_binary(group_id) and byte_size(group_id) > 0 do
    case Repo.get(Group, group_id) do
      %Group{guest_id: guest_id} -> {:guest, guest_id}
      nil -> {:group, group_id}
    end
  end

  defp group_lock(_group_id), do: nil

  defp transfer_lock(operation) do
    source_group_id = field(operation, "source_group_id")
    destination_group_id = field(operation, "destination_group_id")

    if valid_identifier?(source_group_id) do
      case Repo.get(Group, source_group_id) do
        %Group{guest_id: guest_id} ->
          {:guest, guest_id}

        nil ->
          {:transfer, source_group_id, destination_group_id}
      end
    else
      {:transfer, source_group_id, destination_group_id}
    end
  end

  defp target_group_id(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil -> nil
      operation -> Jason.decode!(operation.result)["group_id"]
    end
  end

  defp target_group_id(_payment_operation_id), do: nil

  defp replay_or_conflict(record, operation, operation_id) do
    if Jason.decode!(record.payload) == normalize_json(operation) do
      Jason.decode!(record.result)
    else
      rejected(operation_id, "operation_id_conflict")
    end
  end

  defp encode_payload(operation), do: operation |> normalize_json() |> Jason.encode!()

  defp normalize_json(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), normalize_json(nested_value)} end)
  end

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)
  defp normalize_json(value), do: value

  defp operation_type(operation) do
    case field(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp process_open(operation, operation_id) do
    if valid_identifier?(operation_id) and required_fields?(operation, open_fields()) do
      group_id = field(operation, "group_id")

      if valid_identifier?(group_id) do
        transaction({:group, group_id}, fn -> open_group(operation, operation_id, group_id) end)
      else
        rejected(operation_id, "invalid_operation")
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_existing(operation, operation_id, kind) do
    group_id = field(operation, "group_id")

    if valid_identifier?(operation_id) and valid_identifier?(group_id) do
      transaction(group_lock(group_id), fn ->
        existing_operation(operation, operation_id, group_id, kind)
      end)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_transfer(operation, operation_id) do
    source_group_id = field(operation, "source_group_id")
    destination_group_id = field(operation, "destination_group_id")

    if valid_identifier?(operation_id) and valid_identifier?(source_group_id) and
         valid_identifier?(destination_group_id) do
      transaction(transfer_lock(operation), fn ->
        transfer_operation(operation, operation_id, source_group_id, destination_group_id)
      end)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_target(operation, operation_id, kind) do
    payment_operation_id = field(operation, "payment_operation_id")

    if valid_identifier?(operation_id) and valid_identifier?(payment_operation_id) do
      transaction(operation_lock(operation), fn ->
        target_operation(operation, operation_id, payment_operation_id, kind)
      end)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp open_group(operation, operation_id, group_id) do
    if Repo.get(Group, group_id) do
      rejected(operation_id, "group_already_exists")
    else
      case validate_open(operation) do
        {:ok, group_attrs, rooms} ->
          group = Repo.insert!(struct(Group, group_attrs))
          Repo.insert_all(Room, Enum.map(rooms, &Map.put(&1, :group_id, group_id)))

          applied(operation_id, %{
            "group_id" => group_id,
            "deposit_due_cents" => group.deposit_due_cents,
            "revision" => group.revision
          })

        {:error, code} ->
          rejected(operation_id, code)
      end
    end
  end

  defp existing_operation(operation, operation_id, group_id, kind) do
    case Repo.get(Group, group_id) do
      nil ->
        rejected(operation_id, "group_not_found")

      group ->
        group = ensure_room_accounting!(group)

        case revision_check(operation, group) do
          :ok ->
            apply_existing(group, operation, operation_id, kind)

          {:stale, expected_revision} ->
            rejected(operation_id, "stale_revision", %{
              "group_id" => group_id,
              "expected_revision" => expected_revision,
              "actual_revision" => group.revision
            })

          :invalid ->
            rejected(operation_id, "invalid_operation")
        end
    end
  end

  defp transfer_operation(operation, operation_id, source_group_id, destination_group_id) do
    case Repo.get(Group, source_group_id) do
      nil ->
        rejected(operation_id, "group_not_found", %{"group_id" => source_group_id})

      source_group ->
        case Repo.get(Group, destination_group_id) do
          nil ->
            rejected(operation_id, "group_not_found", %{"group_id" => destination_group_id})

          destination_group ->
            source_group = ensure_room_accounting!(source_group)
            destination_group = ensure_room_accounting!(destination_group)

            case revision_check_for(operation, "expected_revision", source_group) do
              :ok ->
                case revision_check_for(
                       operation,
                       "destination_expected_revision",
                       destination_group
                     ) do
                  :ok ->
                    apply_transfer(
                      source_group,
                      destination_group,
                      operation,
                      operation_id
                    )

                  {:stale, expected_revision} ->
                    rejected(operation_id, "stale_revision", %{
                      "group_id" => destination_group_id,
                      "expected_revision" => expected_revision,
                      "actual_revision" => destination_group.revision
                    })

                  :invalid ->
                    rejected(operation_id, "invalid_operation")
                end

              {:stale, expected_revision} ->
                rejected(operation_id, "stale_revision", %{
                  "group_id" => source_group_id,
                  "expected_revision" => expected_revision,
                  "actual_revision" => source_group.revision
                })

              :invalid ->
                rejected(operation_id, "invalid_operation")
            end
        end
    end
  end

  defp apply_transfer(source_group, destination_group, operation, operation_id) do
    cond do
      source_group.group_id == destination_group.group_id or
          source_group.guest_id != destination_group.guest_id ->
        rejected(operation_id, "invalid_transfer")

      source_group.status != "active" ->
        rejected(operation_id, "group_not_active", %{"group_id" => source_group.group_id})

      destination_group.status != "active" ->
        rejected(operation_id, "group_not_active", %{"group_id" => destination_group.group_id})

      true ->
        with {:ok, amount_cents} <- validate_payment_amount(operation),
             :ok <- validate_transfer_held_funding(source_group, amount_cents),
             :ok <- validate_transfer_outstanding(destination_group, amount_cents) do
          moved = move_funding!(source_group, destination_group, amount_cents)
          updated_source = update_group_with_totals!(source_group, %{})
          updated_destination = update_group_with_totals!(destination_group, %{})

          transferred_cash =
            moved
            |> Enum.filter(&(&1.kind == :cash))
            |> Enum.reduce(0, &(&1.allocation.amount_cents + &2))

          if transferred_cash > 0 do
            record_finance_event!(operation, %{
              property_id: source_group.property_id,
              transferred_out_cents: transferred_cash
            })

            record_finance_event!(operation, %{
              property_id: destination_group.property_id,
              transferred_in_cents: transferred_cash
            })
          end

          applied(operation_id, %{
            "source_group_id" => source_group.group_id,
            "destination_group_id" => destination_group.group_id,
            "amount_cents" => amount_cents,
            "source_outstanding_deposit_cents" => outstanding(updated_source),
            "destination_outstanding_deposit_cents" => outstanding(updated_destination),
            "source_revision" => updated_source.revision,
            "destination_revision" => updated_destination.revision
          })
        else
          {:error, code} -> rejected(operation_id, code)
        end
    end
  end

  defp validate_transfer_held_funding(group, amount_cents) do
    if amount_cents <= (group.deposit_paid_cents || 0),
      do: :ok,
      else: {:error, "transfer_exceeds_held_funding"}
  end

  defp validate_transfer_outstanding(group, amount_cents) do
    if amount_cents <= outstanding(group),
      do: :ok,
      else: {:error, "transfer_exceeds_outstanding"}
  end

  defp target_operation(operation, operation_id, payment_operation_id, kind) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        rejected(operation_id, "operation_not_found")

      target ->
        target_result = Jason.decode!(target.result)

        case target_result["group_id"] do
          group_id when is_binary(group_id) ->
            case Repo.get(Group, group_id) do
              nil ->
                target_rejection(operation_id, kind)

              group ->
                group = ensure_room_accounting!(group)

                case revision_check(operation, group) do
                  :ok ->
                    apply_target(group, operation, operation_id, target, kind)

                  {:stale, expected_revision} ->
                    rejected(operation_id, "stale_revision", %{
                      "group_id" => group_id,
                      "expected_revision" => expected_revision,
                      "actual_revision" => group.revision
                    })

                  :invalid ->
                    rejected(operation_id, "invalid_operation")
                end
            end

          _ ->
            target_rejection(operation_id, kind)
        end
    end
  end

  defp target_rejection(operation_id, :reduce),
    do: rejected(operation_id, "payment_not_reducible")

  defp target_rejection(operation_id, :chargeback),
    do: rejected(operation_id, "payment_not_chargeable")

  defp apply_existing(group, operation, operation_id, :payment) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      with :ok <- validate_common_date(operation),
           {:ok, amount_cents} <- validate_payment_amount(operation),
           :ok <- validate_outstanding(group, amount_cents) do
        allocate_cash!(group, operation_id, amount_cents)
        updated = update_group_with_totals!(group, %{})

        Repo.insert!(%PaymentAccounting{
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

        record_finance_event!(operation, %{
          property_id: group.property_id,
          received_cents: amount_cents
        })

        applied(operation_id, %{
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding(updated),
          "revision" => updated.revision
        })
      else
        {:error, code} -> rejected(operation_id, code)
      end
    end
  end

  defp apply_existing(group, operation, operation_id, :credit) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      with {:ok, occurred_on} <- operation_date(operation),
           {:ok, amount_cents} <- validate_payment_amount(operation),
           :ok <- validate_outstanding(group, amount_cents),
           {:ok, allocations} <- consume_credit(group, amount_cents, occurred_on, operation_id) do
        updated = update_group_with_totals!(group, %{})

        Enum.each(allocations, fn {lot, amount} ->
          record_finance_event!(operation, %{
            credit_lot_id: lot.id,
            credit_available_delta: -amount
          })
        end)

        applied(operation_id, %{
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding(updated),
          "revision" => updated.revision
        })
      else
        {:error, code} -> rejected(operation_id, code)
      end
    end
  end

  defp apply_existing(group, operation, operation_id, :reschedule) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      case validate_reschedule(operation, group) do
        {:ok, new_arrival_on, new_departure_on} ->
          updated =
            update_group_with_totals!(group, %{
              arrival_on: new_arrival_on,
              departure_on: new_departure_on
            })

          applied(operation_id, %{
            "group_id" => group.group_id,
            "new_arrival_on" => Date.to_iso8601(updated.arrival_on),
            "new_departure_on" => Date.to_iso8601(updated.departure_on),
            "policy_version" => group_policy_version(updated),
            "refundable_until" => refundable_until(updated),
            "revision" => updated.revision
          })

        {:error, code} ->
          rejected(operation_id, code)
      end
    end
  end

  defp apply_existing(group, operation, operation_id, :cancel) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      with {:ok, occurred_on} <- operation_date(operation),
           {:ok, refund_method} <- validate_refund_method(operation) do
        refundable = refundable?(group, occurred_on)

        if refund_method == "hotel_credit" and not refundable do
          rejected(operation_id, "refund_method_not_available")
        else
          room_ids = active_rooms(group) |> Enum.map(& &1.room_id)

          {settlement, updated} =
            settle_rooms!(group, room_ids, occurred_on, operation_id, refund_method, refundable)

          record_settlement_finance_events!(operation, group, settlement)

          applied(operation_id, %{
            "group_id" => group.group_id,
            "refunded_cents" => settlement.refunded_cents,
            "retained_cents" => settlement.retained_cents,
            "credit_issued_cents" => settlement.credit_issued_cents,
            "revision" => updated.revision
          })
        end
      else
        {:error, code} -> rejected(operation_id, code)
      end
    end
  end

  defp apply_existing(group, operation, operation_id, :cancel_rooms) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      with {:ok, room_ids} <- validate_cancel_rooms(operation, group),
           {:ok, occurred_on} <- operation_date(operation),
           {:ok, refund_method} <- validate_refund_method(operation) do
        refundable = refundable?(group, occurred_on)

        if refund_method == "hotel_credit" and not refundable do
          rejected(operation_id, "refund_method_not_available")
        else
          {settlement, updated} =
            settle_rooms!(group, room_ids, occurred_on, operation_id, refund_method, refundable)

          record_settlement_finance_events!(operation, group, settlement)

          applied(operation_id, %{
            "group_id" => group.group_id,
            "cancelled_room_ids" => room_ids,
            "refunded_cents" => settlement.refunded_cents,
            "retained_cents" => settlement.retained_cents,
            "credit_issued_cents" => settlement.credit_issued_cents,
            "revision" => updated.revision
          })
        end
      else
        {:error, code} -> rejected(operation_id, code)
      end
    end
  end

  defp apply_target(group, operation, operation_id, target, :reduce) do
    with {:ok, accounting} <- target_payment_accounting(target, "payment_not_reducible"),
         {:ok, amount_cents} <- validate_reduction_amount(operation),
         :ok <- validate_reducible(accounting, amount_cents) do
      {removed, _remaining, touched_group_ids, removed_by_group} =
        remove_payment_allocations!(accounting, amount_cents)

      update_payment_accounting!(accounting, %{
        held_cents: accounting.held_cents - removed,
        reduced_cents: accounting.reduced_cents + removed
      })

      updated =
        update_groups_after_payment_change!(
          group,
          touched_group_ids,
          %{reduced_cents: group.reduced_cents + removed}
        )

      Enum.each(removed_by_group, fn {group_id, amount} ->
        record_group_cash_event!(operation, group_id, reduced_cents: amount)
      end)

      applied(operation_id, %{
        "payment_operation_id" => target.operation_id,
        "group_id" => group.group_id,
        "amount_cents" => removed,
        "outstanding_deposit_cents" => outstanding(updated),
        "revision" => updated.revision
      })
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp apply_target(group, operation, operation_id, target, :chargeback) do
    with {:ok, accounting} <- target_payment_accounting(target, "payment_not_chargeable"),
         :ok <- validate_chargeable(accounting) do
      held = accounting.held_cents
      refunded = accounting.refunded_cents
      retained = accounting.retained_cents
      converted = accounting.converted_to_credit_cents
      charged_back = held + refunded + retained + converted

      {_removed, _remaining, touched_group_ids, removed_by_group} =
        remove_payment_allocations!(accounting, held)

      dispositions = payment_dispositions(accounting)
      revoked_by_lot = revoke_entitlements!(target.operation_id, operation)

      update_payment_accounting!(accounting, %{
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: accounting.charged_back_cents + charged_back
      })

      updated =
        update_groups_after_chargeback!(group, touched_group_ids, dispositions, charged_back)

      Enum.each(removed_by_group, fn {group_id, amount} ->
        record_group_cash_event!(operation, group_id, charged_back_cents: amount)
      end)

      Enum.each(dispositions, fn disposition ->
        record_group_cash_event!(operation, disposition.group_id,
          refunded_cents: -disposition.refunded_cents,
          retained_cents: -disposition.retained_cents,
          converted_to_credit_cents: -disposition.converted_to_credit_cents,
          charged_back_cents:
            disposition.refunded_cents + disposition.retained_cents +
              disposition.converted_to_credit_cents
        )
      end)

      Enum.each(revoked_by_lot, fn event -> record_finance_event!(operation, event) end)

      applied(operation_id, %{
        "payment_operation_id" => target.operation_id,
        "group_id" => group.group_id,
        "charged_back_cents" => charged_back,
        "outstanding_deposit_cents" => outstanding(updated),
        "revision" => updated.revision
      })
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp target_payment_accounting(target, failure_code) do
    result = Jason.decode!(target.result)

    if target.operation_type == "record_cash_payment" and result["status"] == "applied" do
      case Repo.get(PaymentAccounting, target.operation_id) do
        nil ->
          {:error, failure_code}

        accounting ->
          {:ok, accounting}
      end
    else
      {:error, failure_code}
    end
  end

  defp payment_dispositions(accounting) do
    dispositions =
      Repo.all(
        from disposition in PaymentDisposition,
          where: disposition.payment_operation_id == ^accounting.payment_operation_id
      )

    if dispositions == [] and
         accounting.refunded_cents + accounting.retained_cents +
           accounting.converted_to_credit_cents > 0 do
      [
        %{
          group_id: accounting.group_id,
          refunded_cents: accounting.refunded_cents,
          retained_cents: accounting.retained_cents,
          converted_to_credit_cents: accounting.converted_to_credit_cents
        }
      ]
    else
      dispositions
    end
  end

  defp update_groups_after_payment_change!(group, touched_group_ids, attrs) do
    touched_group_ids
    |> Enum.uniq()
    |> Enum.reject(&(&1 == group.group_id))
    |> Enum.each(fn group_id ->
      Repo.get!(Group, group_id) |> update_group_with_totals!(%{})
    end)

    update_group_with_totals!(group, attrs)
  end

  defp update_groups_after_chargeback!(group, touched_group_ids, dispositions, charged_back) do
    disposition_by_group =
      Enum.group_by(dispositions, & &1.group_id)
      |> Map.new(fn {group_id, records} ->
        {group_id,
         Enum.reduce(records, %{refunded_cents: 0, retained_cents: 0, converted_cents: 0}, fn
           record, totals ->
             %{
               refunded_cents: totals.refunded_cents + record.refunded_cents,
               retained_cents: totals.retained_cents + record.retained_cents,
               converted_cents: totals.converted_cents + record.converted_to_credit_cents
             }
         end)}
      end)

    group_ids =
      ([group.group_id | touched_group_ids] ++ Map.keys(disposition_by_group))
      |> Enum.uniq()

    Enum.each(Enum.reject(group_ids, &(&1 == group.group_id)), fn group_id ->
      current = Repo.get!(Group, group_id)
      disposition = Map.get(disposition_by_group, group_id, %{})

      attrs = %{
        refunded_cents: current.refunded_cents - Map.get(disposition, :refunded_cents, 0),
        retained_cents: current.retained_cents - Map.get(disposition, :retained_cents, 0),
        converted_cents: current.converted_cents - Map.get(disposition, :converted_cents, 0),
        charged_back_cents: current.charged_back_cents
      }

      update_group_with_totals!(current, attrs)
    end)

    disposition = Map.get(disposition_by_group, group.group_id, %{})

    update_group_with_totals!(group, %{
      refunded_cents: group.refunded_cents - Map.get(disposition, :refunded_cents, 0),
      retained_cents: group.retained_cents - Map.get(disposition, :retained_cents, 0),
      converted_cents: group.converted_cents - Map.get(disposition, :converted_cents, 0),
      charged_back_cents: group.charged_back_cents + charged_back
    })
  end

  defp validate_reduction_amount(operation) do
    if has_field?(operation, "amount_cents") do
      case field(operation, "amount_cents") do
        amount when is_integer(amount) and amount > 0 -> {:ok, amount}
        _ -> {:error, "invalid_amount"}
      end
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_reducible(%PaymentAccounting{held_cents: held}, amount) when held > 0 do
    if amount <= held, do: :ok, else: {:error, "reduction_exceeds_held_cash"}
  end

  defp validate_reducible(_accounting, _amount), do: {:error, "payment_not_reducible"}

  defp validate_chargeable(%PaymentAccounting{charged_back_cents: charged_back})
       when charged_back > 0,
       do: {:error, "payment_not_chargeable"}

  defp validate_chargeable(%PaymentAccounting{} = accounting) do
    if accounting.held_cents + accounting.refunded_cents + accounting.retained_cents +
         accounting.converted_to_credit_cents > 0 do
      :ok
    else
      {:error, "payment_not_chargeable"}
    end
  end

  defp validate_chargeable(_accounting), do: {:error, "payment_not_chargeable"}

  defp validate_open(operation) do
    with {:ok, occurred_on} <- parse_date(field(operation, "occurred_on")),
         {:ok, arrival_on} <- parse_date(field(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(field(operation, "departure_on")),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_identifier_fields(operation),
         {:ok, rooms} <- validate_rooms(field(operation, "rooms")),
         :ok <- validate_rate_plan(field(operation, "rate_plan")) do
      nights = Date.diff(departure_on, arrival_on)
      rate_plan = field(operation, "rate_plan")

      room_attrs =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          lodging_total_cents = room.nightly_rate_cents * nights

          deposit_due_cents =
            case rate_plan do
              "advance_purchase" -> lodging_total_cents
              "flexible" -> round_percentage(lodging_total_cents, 20)
            end

          %{
            position: position,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            lodging_total_cents: lodging_total_cents,
            deposit_due_cents: deposit_due_cents,
            status: "active",
            cash_paid_cents: 0,
            credit_paid_cents: 0
          }
        end)

      lodging_total_cents = Enum.reduce(room_attrs, 0, &(&1.lodging_total_cents + &2))
      deposit_due_cents = Enum.reduce(room_attrs, 0, &(&1.deposit_due_cents + &2))

      group_attrs = %{
        group_id: field(operation, "group_id"),
        guest_id: field(operation, "guest_id"),
        property_id: field(operation, "property_id"),
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version_for(rate_plan, occurred_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0,
        room_accounting_initialized: true
      }

      {:ok, group_attrs, room_attrs}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp validate_identifier_fields(operation) do
    if valid_identifier?(field(operation, "group_id")) and
         valid_identifier?(field(operation, "guest_id")) and
         valid_identifier?(field(operation, "property_id")) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    Enum.reduce_while(rooms, {:ok, MapSet.new(), []}, fn room, {:ok, ids, valid_rooms} ->
      room_id = if is_map(room), do: field(room, "room_id"), else: nil
      nightly_rate_cents = if is_map(room), do: field(room, "nightly_rate_cents"), else: nil

      if valid_identifier?(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 and
           not MapSet.member?(ids, room_id) do
        {:cont,
         {:ok, MapSet.put(ids, room_id),
          valid_rooms ++ [%{room_id: room_id, nightly_rate_cents: nightly_rate_cents}]}}
      else
        {:halt, {:error, "invalid_rooms"}}
      end
    end)
    |> case do
      {:ok, _ids, valid_rooms} -> {:ok, valid_rooms}
      {:error, code} -> {:error, code}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_rate_plan(rate_plan) when rate_plan in @valid_rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_stay(%Date{} = arrival_on, %Date{} = departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_common_date(operation) do
    case operation_date(operation) do
      {:ok, _date} -> :ok
      {:error, code} -> {:error, code}
    end
  end

  defp operation_date(operation) do
    if has_field?(operation, "occurred_on") do
      parse_date(field(operation, "occurred_on"))
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_payment_amount(operation) do
    if has_field?(operation, "amount_cents") do
      case field(operation, "amount_cents") do
        amount_cents when is_integer(amount_cents) and amount_cents > 0 -> {:ok, amount_cents}
        _ -> {:error, "invalid_amount"}
      end
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_outstanding(group, amount_cents) do
    if amount_cents <= outstanding(group), do: :ok, else: {:error, "payment_exceeds_outstanding"}
  end

  defp validate_reschedule(operation, %Group{} = group) do
    if not has_field?(operation, "occurred_on") or not has_field?(operation, "new_arrival_on") do
      {:error, "invalid_operation"}
    else
      with {:ok, occurred_on} <- parse_date(field(operation, "occurred_on")),
           {:ok, new_arrival_on} <- parse_date(field(operation, "new_arrival_on")) do
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          stay_length = Date.diff(group.departure_on, group.arrival_on)
          {:ok, new_arrival_on, Date.add(new_arrival_on, stay_length)}
        else
          {:error, "invalid_stay"}
        end
      else
        {:error, _code} -> {:error, "invalid_stay"}
      end
    end
  end

  defp validate_refund_method(operation) do
    method =
      if has_field?(operation, "refund_method"),
        do: field(operation, "refund_method"),
        else: "cash"

    if method in @valid_refund_methods do
      {:ok, method}
    else
      {:error, "refund_method_not_available"}
    end
  end

  defp validate_cancel_rooms(operation, group) do
    if has_field?(operation, "room_ids") and is_list(field(operation, "room_ids")) do
      room_ids = field(operation, "room_ids")
      active_ids = MapSet.new(active_rooms(group), & &1.room_id)

      if room_ids != [] and
           Enum.all?(room_ids, &valid_identifier?/1) and
           length(room_ids) == MapSet.size(MapSet.new(room_ids)) and
           Enum.all?(room_ids, &MapSet.member?(active_ids, &1)) do
        ordered_ids =
          active_rooms(group)
          |> Enum.map(& &1.room_id)
          |> Enum.filter(&(&1 in room_ids))

        {:ok, ordered_ids}
      else
        {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp settle_rooms!(group, room_ids, occurred_on, operation_id, refund_method, refundable) do
    rooms =
      active_rooms(group)
      |> Enum.filter(&(&1.room_id in room_ids))

    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.group_id == ^group.group_id and allocation.room_id in ^room_ids,
          order_by: [asc: allocation.allocation_order, asc: allocation.id]
      )

    credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.group_id and allocation.room_id in ^room_ids,
          order_by: [asc: allocation.id]
      )

    cash_by_room = sum_allocations_by_room(cash_allocations)
    credit_by_room = sum_allocations_by_room(credit_allocations)

    Enum.each(cash_allocations, &Repo.delete!/1)

    Enum.each(cash_allocations, fn allocation ->
      settle_payment_cash!(
        allocation.payment_operation_id,
        allocation.amount_cents,
        refundable,
        refund_method,
        group.group_id
      )
    end)

    credit_movements =
      Enum.map(credit_allocations, fn allocation ->
        lot = Repo.get!(CreditLot, allocation.credit_lot_id)

        movement =
          if refundable do
            return_credit_to_lot!(lot, allocation.amount_cents, occurred_on)
            |> Map.put(:credit_lot_id, lot.id)
          else
            %{
              credit_lot_id: lot.id,
              consumed_cents: allocation.amount_cents,
              credit_available_delta: 0
            }
          end

        Repo.delete!(allocation)
        movement
      end)

    Enum.each(rooms, fn room ->
      room
      |> Changeset.change(%{
        status: "cancelled",
        cash_paid_cents:
          max((room.cash_paid_cents || 0) - Map.get(cash_by_room, room.room_id, 0), 0),
        credit_paid_cents:
          max((room.credit_paid_cents || 0) - Map.get(credit_by_room, room.room_id, 0), 0)
      })
      |> Changeset.change(cash_paid_cents: 0, credit_paid_cents: 0)
      |> Repo.update!()
    end)

    cash = Enum.reduce(cash_allocations, 0, &(&1.amount_cents + &2))
    contributors = Enum.map(cash_allocations, &{&1.payment_operation_id, &1.amount_cents})

    {credit_issued_cents, issued_lot_id} =
      if refundable and refund_method == "hotel_credit" do
        issue_credit!(group, cash, occurred_on, operation_id, contributors)
      else
        {0, nil}
      end

    credit_movements =
      if issued_lot_id do
        [
          %{
            credit_lot_id: issued_lot_id,
            issued_cents: credit_issued_cents,
            credit_available_delta: credit_issued_cents
          }
          | credit_movements
        ]
      else
        credit_movements
      end

    {refunded_cents, retained_cents, converted_cents} =
      cond do
        refundable and refund_method == "cash" -> {cash, 0, 0}
        refundable and refund_method == "hotel_credit" -> {0, 0, cash}
        true -> {0, cash, 0}
      end

    status =
      if active_rooms(group.group_id) == [], do: "cancelled", else: "active"

    updated =
      update_group_with_totals!(group, %{
        status: status,
        refunded_cents: group.refunded_cents + refunded_cents,
        retained_cents: group.retained_cents + retained_cents,
        converted_cents: group.converted_cents + converted_cents
      })

    settlement = %{
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      converted_cents: converted_cents,
      credit_issued_cents: credit_issued_cents,
      credit_movements: credit_movements
    }

    {settlement, updated}
  end

  defp sum_allocations_by_room(allocations) do
    Enum.reduce(allocations, %{}, fn allocation, totals ->
      Map.update(
        totals,
        allocation.room_id,
        allocation.amount_cents,
        &(&1 + allocation.amount_cents)
      )
    end)
  end

  defp settle_payment_cash!(nil, _amount, _refundable, _refund_method, _group_id), do: :ok

  defp settle_payment_cash!(payment_operation_id, amount, refundable, refund_method, group_id) do
    accounting = Repo.get!(PaymentAccounting, payment_operation_id)

    disposition =
      cond do
        refundable and refund_method == "cash" -> :refunded_cents
        refundable and refund_method == "hotel_credit" -> :converted_to_credit_cents
        true -> :retained_cents
      end

    attrs =
      Map.put(
        %{held_cents: accounting.held_cents - amount},
        disposition,
        Map.fetch!(accounting, disposition) + amount
      )

    update_payment_accounting!(accounting, attrs)
    record_payment_disposition!(payment_operation_id, group_id, disposition, amount)
  end

  defp record_payment_disposition!(payment_operation_id, group_id, disposition, amount) do
    disposition_attrs = %{
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0
    }

    attrs = Map.put(disposition_attrs, disposition, amount)

    case Repo.get_by(PaymentDisposition,
           payment_operation_id: payment_operation_id,
           group_id: group_id
         ) do
      nil ->
        Repo.insert!(%PaymentDisposition{
          payment_operation_id: payment_operation_id,
          group_id: group_id,
          refunded_cents: attrs.refunded_cents,
          retained_cents: attrs.retained_cents,
          converted_to_credit_cents: attrs.converted_to_credit_cents
        })

      disposition_record ->
        disposition_record
        |> Changeset.change(
          refunded_cents: disposition_record.refunded_cents + attrs.refunded_cents,
          retained_cents: disposition_record.retained_cents + attrs.retained_cents,
          converted_to_credit_cents:
            disposition_record.converted_to_credit_cents + attrs.converted_to_credit_cents
        )
        |> Repo.update!()
    end
  end

  defp issue_credit!(_group, 0, _occurred_on, _operation_id, _contributors), do: {0, nil}

  defp issue_credit!(group, cash_cents, occurred_on, operation_id, contributors) do
    credit_issued_cents = cash_cents + round_percentage(cash_cents, 10)

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued_cents,
        issued_on: occurred_on,
        expires_on: Date.add(occurred_on, 365),
        unrecovered_clawback_cents: 0
      })

    {_cash_so_far, _credit_so_far} =
      Enum.reduce(contributors, {0, 0}, fn {payment_operation_id, amount},
                                           {cash_so_far, credit_so_far} ->
        next_cash = cash_so_far + amount
        next_credit = next_cash + round_percentage(next_cash, 10)
        entitlement = next_credit - credit_so_far

        if is_binary(payment_operation_id) and entitlement > 0 do
          Repo.insert!(%CreditEntitlement{
            credit_lot_id: lot.id,
            payment_operation_id: payment_operation_id,
            amount_cents: entitlement,
            revoked_cents: 0
          })
        end

        {next_cash, next_credit}
      end)

    {credit_issued_cents, lot.id}
  end

  defp consume_credit(group, amount_cents, occurred_on, operation_id) do
    lots = available_credit_lots(group.guest_id, occurred_on)

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) < amount_cents do
      {:error, "insufficient_credit"}
    else
      allocations = take_credit_lots(lots, amount_cents)

      Enum.each(allocations, fn {lot, amount} ->
        lot
        |> Changeset.change(remaining_cents: lot.remaining_cents - amount)
        |> Repo.update!()

        allocate_credit!(group, lot.id, amount, operation_id)
      end)

      {:ok, allocations}
    end
  end

  defp take_credit_lots(lots, amount_cents) do
    {allocations, _remaining} =
      Enum.reduce_while(lots, {[], amount_cents}, fn lot, {allocations, remaining} ->
        amount = min(lot.remaining_cents, remaining)
        next = {[{lot, amount} | allocations], remaining - amount}

        if elem(next, 1) == 0, do: {:halt, next}, else: {:cont, next}
      end)

    Enum.reverse(allocations)
  end

  defp return_credit_to_lot!(lot, amount, occurred_on) do
    unrecovered = lot.unrecovered_clawback_cents || 0
    absorbed = min(unrecovered, amount)
    available_amount = amount - absorbed
    expired = Date.compare(lot.expires_on, occurred_on) == :lt

    remaining_cents =
      if not expired,
        do: lot.remaining_cents + available_amount,
        else: lot.remaining_cents

    lot
    |> Changeset.change(
      remaining_cents: remaining_cents,
      unrecovered_clawback_cents: unrecovered - absorbed
    )
    |> Repo.update!()

    %{
      credit_available_delta: if(expired, do: 0, else: available_amount),
      expired_cents: if(expired, do: available_amount, else: 0),
      absorbed_cents: absorbed
    }
  end

  defp revoke_entitlements!(payment_operation_id, operation) do
    posting_on =
      case Repo.get(FinanceReporting, 1) do
        nil -> nil
        _reporting -> finance_posting_date(operation)
      end

    entitlements =
      Repo.all(
        from entitlement in CreditEntitlement,
          where: entitlement.payment_operation_id == ^payment_operation_id,
          order_by: [asc: entitlement.id]
      )

    Enum.map(entitlements, fn entitlement ->
      outstanding = entitlement.amount_cents - entitlement.revoked_cents

      if outstanding > 0 do
        lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
        removed = min(lot.remaining_cents, outstanding)

        lot
        |> Changeset.change(
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents:
            (lot.unrecovered_clawback_cents || 0) + outstanding - removed
        )
        |> Repo.update!()

        entitlement
        |> Changeset.change(revoked_cents: entitlement.amount_cents)
        |> Repo.update!()

        %{
          credit_lot_id: lot.id,
          credit_available_delta: -removed,
          revoked_cents:
            if(is_nil(posting_on) or Date.compare(lot.expires_on, posting_on) == :lt,
              do: 0,
              else: removed
            )
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp move_funding!(source_group, destination_group, amount_cents) do
    ensure_allocation_orders!(source_group.group_id)
    ensure_allocation_orders!(destination_group.group_id)

    allocations = funding_allocations(source_group.group_id)

    {moved, remaining} =
      Enum.reduce_while(allocations, {[], amount_cents}, fn allocation, {moved, remaining} ->
        amount = min(allocation.allocation.amount_cents, remaining)

        if amount > 0 do
          remove_funding_allocation!(allocation, amount)
          decrease_room_funding!(allocation, amount)

          next =
            {[
               %{allocation | allocation: Map.put(allocation.allocation, :amount_cents, amount)}
               | moved
             ], remaining - amount}

          if elem(next, 1) == 0, do: {:halt, next}, else: {:cont, next}
        else
          {:cont, {moved, remaining}}
        end
      end)

    if remaining != 0, do: raise("deposit transfer exceeded source allocations")

    moved = Enum.reverse(moved)
    {transferred_payment_ids, _rooms} = allocate_transferred_funding!(destination_group, moved)

    Enum.each(transferred_payment_ids, fn payment_operation_id ->
      case Repo.get(PaymentAccounting, payment_operation_id) do
        nil -> :ok
        accounting -> update_payment_accounting!(accounting, transfer_participated: true)
      end
    end)

    moved
  end

  defp funding_allocations(group_id) do
    cash_allocations =
      Repo.all(from allocation in CashAllocation, where: allocation.group_id == ^group_id)
      |> Enum.map(&%{kind: :cash, allocation: &1})

    credit_allocations =
      Repo.all(from allocation in CreditAllocation, where: allocation.group_id == ^group_id)
      |> Enum.map(&%{kind: :credit, allocation: &1})

    (cash_allocations ++ credit_allocations)
    |> Enum.sort_by(
      fn %{kind: kind, allocation: allocation} ->
        {allocation.allocation_order || 0, allocation.id, if(kind == :cash, do: 0, else: 1)}
      end,
      :desc
    )
  end

  defp remove_funding_allocation!(%{allocation: allocation}, amount)
       when amount == allocation.amount_cents,
       do: Repo.delete!(allocation)

  defp remove_funding_allocation!(%{allocation: allocation}, amount) do
    allocation
    |> Changeset.change(amount_cents: allocation.amount_cents - amount)
    |> Repo.update!()
  end

  defp decrease_room_funding!(%{kind: kind, allocation: allocation}, amount) do
    room = Repo.get_by!(Room, group_id: allocation.group_id, room_id: allocation.room_id)
    field = if kind == :cash, do: :cash_paid_cents, else: :credit_paid_cents

    room
    |> Changeset.change([{field, max(Map.get(room, field) - amount, 0)}])
    |> Repo.update!()
  end

  defp allocate_transferred_funding!(group, allocations) do
    Enum.reduce(allocations, {MapSet.new(), active_rooms(group)}, fn allocation,
                                                                     {payment_ids, rooms} ->
      {new_payment_ids, rooms} = allocate_transferred_allocation!(group, allocation, rooms)
      {MapSet.union(payment_ids, new_payment_ids), rooms}
    end)
  end

  defp allocate_transferred_allocation!(group, %{kind: kind, allocation: allocation}, rooms) do
    {remaining, rooms, payment_ids} =
      Enum.reduce_while(Enum.with_index(rooms), {allocation.amount_cents, rooms, MapSet.new()}, fn
        {room, position}, {remaining, rooms, payment_ids} ->
          amount = min(room_capacity(room), remaining)

          if amount > 0 do
            insert_transferred_allocation!(group, room, kind, allocation, amount)

            field = if kind == :cash, do: :cash_paid_cents, else: :credit_paid_cents
            update_room_funding!(room, [{field, Map.get(room, field) + amount}])
            updated_room = Map.put(room, field, Map.get(room, field) + amount)
            rooms = List.replace_at(rooms, position, updated_room)

            payment_ids =
              if kind == :cash and is_binary(allocation.payment_operation_id),
                do: MapSet.put(payment_ids, allocation.payment_operation_id),
                else: payment_ids

            next = {remaining - amount, rooms, payment_ids}
            if elem(next, 0) == 0, do: {:halt, next}, else: {:cont, next}
          else
            {:cont, {remaining, rooms, payment_ids}}
          end
      end)

    if remaining != 0, do: raise("deposit transfer exceeded destination capacity")
    {payment_ids, rooms}
  end

  defp insert_transferred_allocation!(group, room, :cash, allocation, amount) do
    Repo.insert!(%CashAllocation{
      payment_operation_id: allocation.payment_operation_id,
      group_id: group.group_id,
      room_id: room.room_id,
      amount_cents: amount,
      allocation_order: next_allocation_order!()
    })
  end

  defp insert_transferred_allocation!(group, room, :credit, allocation, amount) do
    Repo.insert!(%CreditAllocation{
      credit_lot_id: allocation.credit_lot_id,
      group_id: group.group_id,
      room_id: room.room_id,
      funding_operation_id: allocation.funding_operation_id,
      amount_cents: amount,
      allocation_order: next_allocation_order!()
    })
  end

  defp ensure_allocation_orders!(group_id) do
    missing_cash =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.group_id == ^group_id and is_nil(allocation.allocation_order),
          order_by: [asc: allocation.id]
      )
      |> Enum.map(&%{kind: :cash, allocation: &1})

    missing_credit =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group_id and is_nil(allocation.allocation_order),
          order_by: [asc: allocation.id]
      )
      |> Enum.map(&%{kind: :credit, allocation: &1})

    operation_orders =
      Repo.all(from operation in Operation, select: {operation.operation_id, operation.id})
      |> Map.new()

    missing_allocations =
      (missing_cash ++ missing_credit)
      |> Enum.sort_by(&allocation_creation_key(&1, operation_orders))

    {cash_max, credit_max} =
      {
        Repo.one(from allocation in CashAllocation, select: max(allocation.allocation_order)),
        Repo.one(from allocation in CreditAllocation, select: max(allocation.allocation_order))
      }

    starting_order = max(cash_max || 0, credit_max || 0)

    Enum.reduce(missing_allocations, starting_order, fn %{allocation: allocation}, order ->
      next_order = order + 1

      allocation
      |> Changeset.change(allocation_order: next_order)
      |> Repo.update!()

      next_order
    end)
  end

  defp allocation_creation_key(%{kind: kind, allocation: allocation}, operation_orders) do
    operation_id =
      if kind == :cash, do: allocation.payment_operation_id, else: allocation.funding_operation_id

    kind_order = if kind == :cash, do: 0, else: 1

    case operation_id do
      nil -> {0, kind_order, 0, allocation.id}
      operation_id -> {1, Map.get(operation_orders, operation_id, 0), kind_order, allocation.id}
    end
  end

  defp next_allocation_order! do
    cash_max =
      Repo.one(from allocation in CashAllocation, select: max(allocation.allocation_order))

    credit_max =
      Repo.one(from allocation in CreditAllocation, select: max(allocation.allocation_order))

    max(cash_max || 0, credit_max || 0) + 1
  end

  defp allocate_cash!(group, payment_operation_id, amount_cents) do
    {remaining, _rooms} =
      Enum.reduce_while(active_rooms(group), {amount_cents, []}, fn room, {remaining, rooms} ->
        capacity = room_capacity(room)
        amount = min(capacity, remaining)

        if amount > 0 do
          Repo.insert!(%CashAllocation{
            payment_operation_id: payment_operation_id,
            group_id: group.group_id,
            room_id: room.room_id,
            amount_cents: amount,
            allocation_order: next_allocation_order!()
          })

          update_room_funding!(room, cash_paid_cents: (room.cash_paid_cents || 0) + amount)
        end

        next = {remaining - amount, [room | rooms]}
        if elem(next, 0) == 0, do: {:halt, next}, else: {:cont, next}
      end)

    if remaining != 0, do: raise("cash allocation exceeded active room capacity")
  end

  defp allocate_credit!(group, credit_lot_id, amount_cents, operation_id) do
    {remaining, _rooms} =
      Enum.reduce_while(active_rooms(group), {amount_cents, []}, fn room, {remaining, rooms} ->
        capacity = room_capacity(room)
        amount = min(capacity, remaining)

        if amount > 0 do
          Repo.insert!(%CreditAllocation{
            credit_lot_id: credit_lot_id,
            group_id: group.group_id,
            room_id: room.room_id,
            funding_operation_id: operation_id,
            amount_cents: amount,
            allocation_order: next_allocation_order!()
          })

          update_room_funding!(room, credit_paid_cents: (room.credit_paid_cents || 0) + amount)
        end

        next = {remaining - amount, [room | rooms]}
        if elem(next, 0) == 0, do: {:halt, next}, else: {:cont, next}
      end)

    if remaining != 0, do: raise("credit allocation exceeded active room capacity")
  end

  defp remove_payment_allocations!(accounting, amount_cents) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.payment_operation_id == ^accounting.payment_operation_id,
          order_by: [desc: allocation.allocation_order, desc: allocation.id]
      )

    {removed, remaining, touched_group_ids} =
      Enum.reduce_while(allocations, {0, amount_cents, MapSet.new()}, fn
        allocation, {removed, remaining, touched_group_ids} ->
          amount = min(allocation.amount_cents, remaining)
          room = Repo.get_by!(Room, group_id: allocation.group_id, room_id: allocation.room_id)

          if amount == allocation.amount_cents do
            Repo.delete!(allocation)
          else
            allocation
            |> Changeset.change(amount_cents: allocation.amount_cents - amount)
            |> Repo.update!()
          end

          room
          |> Changeset.change(cash_paid_cents: max((room.cash_paid_cents || 0) - amount, 0))
          |> Repo.update!()

          next =
            {removed + amount, remaining - amount,
             MapSet.put(touched_group_ids, allocation.group_id)}

          if elem(next, 1) == 0, do: {:halt, next}, else: {:cont, next}
      end)

    removed_by_group =
      allocations
      |> Enum.reduce_while({amount_cents, %{}}, fn allocation, {remaining, totals} ->
        amount = min(allocation.amount_cents, remaining)

        if amount == 0 do
          {:halt, {remaining, totals}}
        else
          next =
            {remaining - amount, Map.update(totals, allocation.group_id, amount, &(&1 + amount))}

          if elem(next, 0) == 0, do: {:halt, next}, else: {:cont, next}
        end
      end)
      |> elem(1)

    {removed, remaining, MapSet.to_list(touched_group_ids), removed_by_group}
  end

  defp update_room_funding!(room, attrs) do
    room |> Changeset.change(attrs) |> Repo.update!()
  end

  defp room_capacity(room),
    do:
      max(
        (room.deposit_due_cents || 0) - (room.cash_paid_cents || 0) -
          (room.credit_paid_cents || 0),
        0
      )

  defp active_rooms(%Group{} = group), do: active_rooms(group.group_id)

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: room.position
    )
  end

  defp update_group_with_totals!(group, attrs) do
    totals = room_totals(group.group_id)

    group
    |> Changeset.change(
      Map.merge(attrs, %{
        lodging_total_cents: totals.lodging_total_cents,
        deposit_due_cents: totals.deposit_due_cents,
        deposit_paid_cents: totals.deposit_paid_cents,
        cash_paid_cents: totals.cash_paid_cents,
        credit_paid_cents: totals.credit_paid_cents,
        revision: group.revision + 1
      })
    )
    |> Repo.update!()
  end

  defp room_totals(group_id) do
    Repo.one(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        select: %{
          lodging_total_cents: coalesce(sum(room.lodging_total_cents), 0),
          deposit_due_cents: coalesce(sum(room.deposit_due_cents), 0),
          deposit_paid_cents: coalesce(sum(room.cash_paid_cents + room.credit_paid_cents), 0),
          cash_paid_cents: coalesce(sum(room.cash_paid_cents), 0),
          credit_paid_cents: coalesce(sum(room.credit_paid_cents), 0)
        }
    )
  end

  defp group_payload(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: room.position
      )

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group_policy_version(group),
      "refundable_until" => refundable_until(group),
      "status" => group.status,
      "rooms" => Enum.map(rooms, &room_payload/1),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => cash_paid(group),
      "credit_paid_cents" => credit_paid(group),
      "outstanding_deposit_cents" => outstanding(group)
    }
  end

  defp room_payload(room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "lodging_total_cents" => room.lodging_total_cents,
      "status" => room.status,
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => room.cash_paid_cents || 0,
      "credit_paid_cents" => room.credit_paid_cents || 0
    }
  end

  defp group_policy_version(%Group{policy_version: policy_version})
       when policy_version in @valid_policy_versions,
       do: policy_version

  defp group_policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version_for(rate_plan, booked_on)

  defp policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp cancellation_window("flex-14"), do: 14
  defp cancellation_window("flex-30"), do: 30
  defp cancellation_window("advance-nonrefundable"), do: nil

  defp refundable_until(group) do
    case cancellation_window(group_policy_version(group)) do
      nil -> nil
      window -> Date.to_iso8601(Date.add(group.arrival_on, -window))
    end
  end

  defp refundable?(group, occurred_on) do
    case cancellation_window(group_policy_version(group)) do
      nil -> false
      window -> Date.compare(occurred_on, Date.add(group.arrival_on, -window)) != :gt
    end
  end

  defp outstanding(%Group{status: "active", deposit_due_cents: due} = group),
    do: due - group.deposit_paid_cents

  defp outstanding(%Group{}), do: 0

  defp cash_paid(%Group{cash_paid_cents: nil, deposit_paid_cents: paid}), do: paid
  defp cash_paid(%Group{cash_paid_cents: paid}), do: paid

  defp credit_paid(%Group{credit_paid_cents: nil}), do: 0
  defp credit_paid(%Group{credit_paid_cents: paid}), do: paid

  defp sum_active(field_name) do
    Repo.one(
      from group in Group,
        where: group.status == "active",
        select: coalesce(sum(field(group, ^field_name)), 0)
    )
  end

  defp sum_all(field_name) do
    Repo.one(from group in Group, select: coalesce(sum(field(group, ^field_name)), 0))
  end

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.issued_on <= ^as_of and lot.expires_on >= ^as_of,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + applied
  end

  defp credit_shortfall do
    applied_by_lot =
      Repo.all(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active",
          group_by: allocation.credit_lot_id,
          select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
      )
      |> Map.new()

    Repo.all(from lot in CreditLot, select: {lot.id, lot.unrecovered_clawback_cents})
    |> Enum.reduce(0, fn {lot_id, unrecovered}, total ->
      total + min(unrecovered || 0, Map.get(applied_by_lot, lot_id, 0))
    end)
  end

  defp available_credit_lots(guest_id, as_of) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^as_of and
            lot.expires_on >= ^as_of,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp credit_lot_payload(lot) do
    %{
      "source_operation_id" => lot.source_operation_id,
      "remaining_cents" => lot.remaining_cents,
      "expires_on" => Date.to_iso8601(lot.expires_on)
    }
  end

  defp payment_payload(accounting) do
    payload = %{
      "payment_operation_id" => accounting.payment_operation_id,
      "original_group_id" => accounting.group_id,
      "recorded_cents" => accounting.recorded_cents,
      "held_cents" => accounting.held_cents,
      "refunded_cents" => accounting.refunded_cents,
      "retained_cents" => accounting.retained_cents,
      "converted_to_credit_cents" => accounting.converted_to_credit_cents,
      "reduced_cents" => accounting.reduced_cents,
      "charged_back_cents" => accounting.charged_back_cents
    }

    if accounting.transfer_participated do
      Map.put(payload, "held_by_group", held_cash_by_group(accounting.payment_operation_id))
    else
      payload
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id,
        group_by: allocation.group_id,
        order_by: [asc: allocation.group_id],
        select: {allocation.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  defp maybe_initialize_payment_group!(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      %Group{room_accounting_initialized: false} = group ->
        Repo.transaction(fn -> ensure_room_accounting!(group) end)
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_initialize_payment_group!(_group_id), do: :ok

  defp update_payment_accounting!(accounting, attrs) do
    accounting |> Changeset.change(attrs) |> Repo.update!()
  end

  defp ensure_room_accounting!(%Group{room_accounting_initialized: true} = group), do: group

  defp ensure_room_accounting!(%Group{} = group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: room.position
      )

    rooms = Enum.map(rooms, &backfill_room_values!(&1, group))

    if group.status == "active" do
      backfill_active_group!(group, rooms)
    else
      Enum.each(rooms, fn room ->
        room
        |> Changeset.change(status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0)
        |> Repo.update!()
      end)
    end

    totals = room_totals(group.group_id)

    group
    |> Changeset.change(
      Map.merge(totals, %{
        room_accounting_initialized: true,
        status: if(group.status == "active", do: "active", else: "cancelled")
      })
    )
    |> Repo.update!()
  end

  defp backfill_room_values!(room, group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    lodging_total_cents =
      if is_integer(room.lodging_total_cents) and room.lodging_total_cents > 0,
        do: room.lodging_total_cents,
        else: room.nightly_rate_cents * nights

    deposit_due_cents =
      if is_integer(room.deposit_due_cents) and room.deposit_due_cents > 0 do
        room.deposit_due_cents
      else
        case group.rate_plan do
          "advance_purchase" -> lodging_total_cents
          _ -> round_percentage(lodging_total_cents, 20)
        end
      end

    room
    |> Changeset.change(
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      status: room.status || "active",
      cash_paid_cents: room.cash_paid_cents || 0,
      credit_paid_cents: room.credit_paid_cents || 0
    )
    |> Repo.update!()
  end

  defp backfill_active_group!(group, _rooms) do
    records = legacy_funding_records(group.group_id)

    old_credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.group_id,
          order_by: [asc: allocation.id]
      )

    Repo.delete_all(
      from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id
    )

    represented_cash =
      records
      |> Enum.filter(&(&1.type == "record_cash_payment"))
      |> Enum.reduce(0, &(&1.amount + &2))

    legacy_cash = max((cash_paid(group) || 0) - represented_cash, 0)

    represented_credit =
      records
      |> Enum.filter(&(&1.type == "apply_hotel_credit"))
      |> Enum.reduce(0, &(&1.amount + &2))

    legacy_credit = max((credit_paid(group) || 0) - represented_credit, 0)

    allocate_cash_block!(group, legacy_cash, nil)

    queue = Enum.map(old_credit_allocations, &{&1.credit_lot_id, &1.amount_cents})
    queue = allocate_credit_queue!(group, queue, legacy_credit, nil)

    Enum.reduce(records, queue, fn record, queue ->
      case record.type do
        "record_cash_payment" ->
          ensure_backfilled_payment!(record, group)
          allocate_cash_block!(group, record.amount, record.operation_id)
          queue

        "apply_hotel_credit" ->
          allocate_credit_queue!(group, queue, record.amount, record.operation_id)
      end
    end)
  end

  defp allocate_cash_block!(_group, 0, _operation_id), do: :ok

  defp allocate_cash_block!(group, amount, operation_id) do
    {remaining, _} =
      Enum.reduce_while(active_rooms(group), {amount, []}, fn room, acc ->
        {remaining, rooms} = acc
        assigned = min(room_capacity(room), remaining)

        if assigned > 0 do
          Repo.insert!(%CashAllocation{
            payment_operation_id: operation_id,
            group_id: group.group_id,
            room_id: room.room_id,
            amount_cents: assigned,
            allocation_order: next_allocation_order!()
          })

          update_room_funding!(room, cash_paid_cents: (room.cash_paid_cents || 0) + assigned)
        end

        next = {remaining - assigned, [room | rooms]}
        if elem(next, 0) == 0, do: {:halt, next}, else: {:cont, next}
      end)

    if remaining != 0, do: raise("legacy cash allocation exceeded room capacity")
  end

  defp allocate_credit_queue!(_group, queue, 0, _operation_id), do: queue

  defp allocate_credit_queue!(group, queue, amount, operation_id) do
    {queue, remaining} = allocate_credit_queue_rooms!(group, queue, amount, operation_id)
    if remaining != 0, do: raise("legacy credit allocation exceeded room capacity")
    queue
  end

  defp allocate_credit_queue_rooms!(group, queue, amount, operation_id) do
    Enum.reduce_while(active_rooms(group), {queue, amount}, fn room, {queue, remaining} ->
      capacity = room_capacity(room)
      room_amount = min(capacity, remaining)
      {queue, room_amount} = allocate_credit_queue_room!(queue, room, room_amount, operation_id)
      next = {queue, remaining - room_amount}
      if elem(next, 1) == 0, do: {:halt, next}, else: {:cont, next}
    end)
  end

  defp allocate_credit_queue_room!(queue, _room, 0, _operation_id), do: {queue, 0}

  defp allocate_credit_queue_room!(queue, room, amount, operation_id) do
    {queue, assigned} =
      Enum.reduce_while(queue, {queue, 0}, fn {lot_id, available}, {remaining_queue, assigned} ->
        amount_left = amount - assigned
        take = min(available, amount_left)

        if take > 0 do
          Repo.insert!(%CreditAllocation{
            credit_lot_id: lot_id,
            group_id: room.group_id,
            room_id: room.room_id,
            funding_operation_id: operation_id,
            amount_cents: take,
            allocation_order: next_allocation_order!()
          })
        end

        next_queue =
          if take == available do
            List.delete(remaining_queue, {lot_id, available})
          else
            List.replace_at(remaining_queue, 0, {lot_id, available - take})
          end

        next = {next_queue, assigned + take}
        if elem(next, 1) == amount, do: {:halt, next}, else: {:cont, next}
      end)

    if assigned > 0 do
      update_room_funding!(room, credit_paid_cents: (room.credit_paid_cents || 0) + assigned)
    end

    {queue, assigned}
  end

  defp legacy_funding_records(group_id) do
    Repo.all(from operation in Operation, order_by: operation.id)
    |> Enum.flat_map(fn operation ->
      result = Jason.decode!(operation.result)

      if result["status"] == "applied" and result["group_id"] == group_id and
           operation.operation_type in ["record_cash_payment", "apply_hotel_credit"] do
        [
          %{
            operation_id: operation.operation_id,
            type: operation.operation_type,
            amount: result["amount_cents"]
          }
        ]
      else
        []
      end
    end)
  end

  defp ensure_backfilled_payment!(record, group) do
    unless Repo.get(PaymentAccounting, record.operation_id) do
      Repo.insert!(%PaymentAccounting{
        payment_operation_id: record.operation_id,
        group_id: group.group_id,
        recorded_cents: record.amount,
        held_cents: record.amount,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0,
        transfer_participated: false
      })
    end
  end

  defp initialize_legacy_groups! do
    Repo.all(from group in Group, where: group.room_accounting_initialized == false)
    |> Enum.each(fn group ->
      Repo.transaction(fn ->
        case Repo.get(Group, group.group_id) do
          nil -> :ok
          current -> ensure_room_accounting!(current)
        end
      end)
    end)
  end

  defp reporting_date(operation) do
    if has_field?(operation, "starts_on") do
      parse_reporting_date(field(operation, "starts_on"))
    else
      {:error, :invalid_reporting_date}
    end
  end

  defp parse_reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  defp parse_reporting_date(_value), do: {:error, :invalid_reporting_date}

  defp capture_reporting_opening!(starts_on) do
    Repo.insert!(%FinanceReporting{id: 1, starts_on: starts_on})

    Repo.all(
      from group in Group,
        where: group.status == "active",
        group_by: group.property_id,
        select: {group.property_id, coalesce(sum(group.cash_paid_cents), 0)}
    )
    |> Enum.each(fn {property_id, held_cents} ->
      Repo.insert!(%FinanceOpeningCash{property_id: property_id, held_cents: held_cents})
    end)

    applied_by_lot =
      Repo.all(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active",
          group_by: allocation.credit_lot_id,
          select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
      )
      |> Map.new()

    Repo.all(from(lot in CreditLot))
    |> Enum.each(fn lot ->
      available_cents =
        if Date.compare(lot.expires_on, starts_on) != :lt,
          do: max(lot.remaining_cents || 0, 0),
          else: 0

      liability_cents = available_cents + Map.get(applied_by_lot, lot.id, 0)

      if liability_cents > 0 do
        Repo.insert!(%FinanceOpeningCredit{
          credit_lot_id: lot.id,
          available_cents: available_cents,
          liability_cents: liability_cents,
          expires_on: lot.expires_on
        })
      end
    end)
  end

  defp record_settlement_finance_events!(operation, group, settlement) do
    if Repo.get(FinanceReporting, 1) do
      record_group_cash_event!(operation, group.group_id,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        converted_to_credit_cents: settlement.converted_cents
      )

      Enum.each(settlement.credit_movements, fn movement ->
        movement =
          case movement do
            %{credit_lot_id: lot_id, issued_cents: issued_cents} when issued_cents > 0 ->
              lot = Repo.get!(CreditLot, lot_id)

              if Date.compare(lot.expires_on, finance_posting_date(operation)) == :lt do
                Map.merge(movement, %{credit_available_delta: 0, expired_cents: issued_cents})
              else
                movement
              end

            _ ->
              movement
          end

        record_finance_event!(operation, movement)
      end)
    end
  end

  defp record_group_cash_event!(operation, group_id, attrs) do
    case Repo.get(Group, group_id) do
      nil ->
        :ok

      group ->
        record_finance_event!(operation, Map.put(Map.new(attrs), :property_id, group.property_id))
    end
  end

  defp record_finance_event!(operation, attrs) do
    if Repo.get(FinanceReporting, 1) do
      attrs =
        Map.merge(
          %{
            operation_id: field(operation, "operation_id"),
            posting_on: finance_posting_date(operation),
            property_id: nil,
            credit_lot_id: nil,
            credit_available_delta: 0,
            received_cents: 0,
            transferred_in_cents: 0,
            transferred_out_cents: 0,
            refunded_cents: 0,
            retained_cents: 0,
            converted_to_credit_cents: 0,
            reduced_cents: 0,
            charged_back_cents: 0,
            issued_cents: 0,
            expired_cents: 0,
            consumed_cents: 0,
            revoked_cents: 0,
            absorbed_cents: 0
          },
          attrs
        )

      values =
        Map.take(attrs, [
          :credit_available_delta,
          :received_cents,
          :transferred_in_cents,
          :transferred_out_cents,
          :refunded_cents,
          :retained_cents,
          :converted_to_credit_cents,
          :reduced_cents,
          :charged_back_cents,
          :issued_cents,
          :expired_cents,
          :consumed_cents,
          :revoked_cents,
          :absorbed_cents
        ])

      unless Enum.all?(values, fn {_key, value} -> value == 0 end) do
        Repo.insert!(struct(FinanceEvent, attrs))
      end
    end
  end

  defp finance_posting_date(operation) do
    starts_on = Repo.get!(FinanceReporting, 1).starts_on

    occurred_on =
      if has_field?(operation, "occurred_on") do
        case parse_reporting_date(field(operation, "occurred_on")) do
          {:ok, date} -> date
          {:error, _reason} -> starts_on
        end
      else
        starts_on
      end

    if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
  end

  defp build_daily_report(reporting, report_date) do
    events =
      Repo.all(
        from event in FinanceEvent,
          where: event.posting_on <= ^report_date,
          order_by: [asc: event.id]
      )

    cash = build_cash_report(reporting, report_date, events)
    credit = build_credit_report(reporting, report_date, events)

    %{
      "date" => Date.to_iso8601(report_date),
      "status" => "open",
      "cash" => cash,
      "credit" => credit
    }
  end

  defp build_cash_report(_reporting, report_date, events) do
    opening =
      Repo.all(from cash in FinanceOpeningCash, select: {cash.property_id, cash.held_cents})
      |> Map.new()

    events_by_property =
      events
      |> Enum.filter(&is_binary(&1.property_id))
      |> Enum.group_by(& &1.property_id)

    (Map.keys(opening) ++ Map.keys(events_by_property))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      property_events = Map.get(events_by_property, property_id, [])
      opening_held_cents = Map.get(opening, property_id, 0)

      movements = %{
        "received_cents" => sum_events_on(property_events, report_date, :received_cents),
        "transferred_in_cents" =>
          sum_events_on(property_events, report_date, :transferred_in_cents),
        "transferred_out_cents" =>
          sum_events_on(property_events, report_date, :transferred_out_cents),
        "refunded_cents" => sum_events_on(property_events, report_date, :refunded_cents),
        "retained_cents" => sum_events_on(property_events, report_date, :retained_cents),
        "converted_to_credit_cents" =>
          sum_events_on(property_events, report_date, :converted_to_credit_cents),
        "reduced_cents" => sum_events_on(property_events, report_date, :reduced_cents),
        "charged_back_cents" => sum_events_on(property_events, report_date, :charged_back_cents)
      }

      closing_held_cents =
        opening_held_cents +
          Enum.reduce(events, 0, fn event, total ->
            if event.property_id == property_id and
                 Date.compare(event.posting_on, report_date) != :gt do
              total + cash_delta(event)
            else
              total
            end
          end)

      if opening_held_cents != 0 or closing_held_cents != 0 or
           Enum.any?(movements, fn {_key, value} -> value != 0 end) do
        %{
          "property_id" => property_id,
          "opening_held_cents" => opening_held_cents,
          "movements" => movements,
          "closing_held_cents" => closing_held_cents
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp build_credit_report(reporting, report_date, events) do
    synthetic_expired_today = synthetic_expired_cents(reporting, report_date)

    movements = %{
      "issued_cents" => sum_credit_events_on(events, report_date, :issued_cents),
      "expired_cents" =>
        sum_credit_events_on(events, report_date, :expired_cents) +
          synthetic_expired_today,
      "consumed_cents" => sum_credit_events_on(events, report_date, :consumed_cents),
      "revoked_cents" => sum_credit_events_on(events, report_date, :revoked_cents),
      "absorbed_cents" => sum_credit_events_on(events, report_date, :absorbed_cents)
    }

    opening_liability_cents =
      Repo.one(
        from credit in FinanceOpeningCredit, select: coalesce(sum(credit.liability_cents), 0)
      )

    cumulative_expired_cents =
      sum_credit_events_through(events, report_date, :expired_cents) +
        synthetic_expired_cents_through(reporting, report_date)

    closing_liability_cents =
      opening_liability_cents +
        sum_credit_events_through(events, report_date, :issued_cents) - cumulative_expired_cents -
        sum_credit_events_through(events, report_date, :consumed_cents) -
        sum_credit_events_through(events, report_date, :revoked_cents) -
        sum_credit_events_through(events, report_date, :absorbed_cents)

    %{
      "opening_liability_cents" => opening_liability_cents,
      "movements" => movements,
      "closing_liability_cents" => closing_liability_cents
    }
  end

  defp sum_events_on(events, report_date, field_name) do
    Enum.reduce(events, 0, fn event, total ->
      if event.posting_on == report_date, do: total + Map.get(event, field_name), else: total
    end)
  end

  defp sum_credit_events_on(events, report_date, field_name) do
    sum_events_on(Enum.filter(events, &is_integer(&1.credit_lot_id)), report_date, field_name)
  end

  defp sum_credit_events_through(events, report_date, field_name) do
    events
    |> Enum.filter(&is_integer(&1.credit_lot_id))
    |> Enum.reduce(0, fn event, total ->
      total + if(event.posting_on <= report_date, do: Map.get(event, field_name), else: 0)
    end)
  end

  defp cash_delta(event) do
    event.received_cents + event.transferred_in_cents - event.transferred_out_cents -
      event.refunded_cents - event.retained_cents - event.converted_to_credit_cents -
      event.reduced_cents - event.charged_back_cents
  end

  defp synthetic_expired_cents(reporting, report_date) do
    expiration_date = Date.add(report_date, -1)

    if Date.compare(expiration_date, reporting.starts_on) == :lt do
      0
    else
      Repo.all(from lot in CreditLot, where: lot.expires_on == ^expiration_date)
      |> Enum.reduce(0, fn lot, total ->
        total + available_credit_at(lot, report_date)
      end)
    end
  end

  defp synthetic_expired_cents_through(reporting, report_date) do
    Repo.all(from lot in CreditLot, where: lot.expires_on < ^report_date)
    |> Enum.reduce(0, fn lot, total ->
      expiration_date = Date.add(lot.expires_on, 1)

      if Date.compare(expiration_date, reporting.starts_on) != :lt and
           Date.compare(expiration_date, report_date) != :gt do
        total + available_credit_at(lot, expiration_date)
      else
        total
      end
    end)
  end

  defp available_credit_at(lot, date) do
    opening_available =
      case Repo.get(FinanceOpeningCredit, lot.id) do
        nil -> 0
        opening -> opening.available_cents
      end

    moved_before_date =
      Repo.one(
        from event in FinanceEvent,
          where: event.credit_lot_id == ^lot.id and event.posting_on < ^date,
          select: coalesce(sum(event.credit_available_delta), 0)
      )

    max(opening_available + moved_before_date, 0)
  end

  defp transaction(group_id, fun) do
    :global.trans({{__MODULE__, :domain}, group_id}, fn ->
      {:ok, result} = Repo.transaction(fun)
      result
    end)
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)

  defp rejected(operation_id, code, fields \\ %{}),
    do:
      Map.merge(%{"operation_id" => operation_id, "status" => "rejected", "code" => code}, fields)

  defp revision_check(operation, group) do
    revision_check_for(operation, "expected_revision", group)
  end

  defp revision_check_for(operation, field_name, group) do
    case expected_revision(operation, field_name) do
      :absent -> :ok
      {:ok, expected_revision} when expected_revision == group.revision -> :ok
      {:ok, expected_revision} -> {:stale, expected_revision}
      :invalid -> :invalid
    end
  end

  defp expected_revision(operation, field_name) do
    if has_field?(operation, field_name) do
      case field(operation, field_name) do
        revision when is_integer(revision) -> {:ok, revision}
        _ -> :invalid
      end
    else
      :absent
    end
  end

  defp required_fields?(operation, fields), do: Enum.all?(fields, &has_field?(operation, &1))

  defp open_fields do
    [
      "operation_id",
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]
  end

  defp has_field?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_stay"}

  defp parse_as_of(nil), do: {:ok, Date.utc_today()}

  defp parse_as_of(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp parse_as_of(_value), do: {:error, :invalid_date}

  defp round_percentage(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)
end
