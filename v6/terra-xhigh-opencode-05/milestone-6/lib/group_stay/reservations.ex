defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashPaymentDisposition,
    CashPayment,
    CreditLot,
    CreditLotContribution,
    FinanceCashOpening,
    FinanceCreditExpirySchedule,
    FinancePosting,
    FinanceReportingStart,
    Group,
    PartnerOperation,
    Room,
    RoomFundingAllocation
  }

  @rate_plans ["flexible", "advance_purchase"]
  @policy_cutover ~D[2027-01-01]

  def process_batch(operations), do: Enum.map(operations, &process_operation/1)

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :not_found
      group -> {:ok, group_response(group)}
    end
  end

  def get_operation(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> :not_found
      operation -> {:ok, Jason.decode!(operation.result)}
    end
  end

  def get_payment(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        :not_found

      _operation ->
        case Repo.get(CashPayment, operation_id) do
          nil -> :not_reconcilable
          payment -> {:ok, payment_response(payment)}
        end
    end
  end

  def ledger(on \\ Date.utc_today()) do
    %{
      cash_held_cents: cash_held(),
      cash_refunded_cents: group_total(:refunded_cents) + payment_total(:refunded_cents),
      cash_retained_cents: group_total(:retained_cents) + payment_total(:retained_cents),
      cash_converted_to_credit_cents:
        group_total(:cash_converted_to_credit_cents) + payment_total(:converted_to_credit_cents),
      cash_reduced_cents: payment_total(:reduced_cents),
      cash_charged_back_cents: payment_total(:charged_back_cents),
      credit_liability_cents: credit_liability(on),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum_by(lots, & &1.remaining_cents),
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

  def daily_finance_report(date) do
    case reporting_start() do
      nil ->
        :not_available

      start ->
        if Date.compare(date, start.starts_on) == :lt do
          :not_available
        else
          {:ok,
           %{
             date: Date.to_iso8601(date),
             status: "open",
             cash: daily_cash_report(start, date),
             credit: daily_credit_report(start, date)
           }}
        end
    end
  end

  defp process_operation(operation) when is_map(operation) do
    case Map.get(operation, "operation_id") do
      operation_id when is_binary(operation_id) ->
        process_identified_operation(operation, canonical_json(operation))

      _ ->
        process_unidentified_operation(operation)
    end
  end

  defp process_operation(operation), do: process_unidentified_operation(operation)

  defp process_identified_operation(operation, submitted_payload) do
    case Repo.transaction(
           fn ->
             case Repo.get_by(PartnerOperation, operation_id: operation["operation_id"]) do
               nil ->
                 result = apply_operation(operation)

                 if Map.get(result, :code) == "retry" do
                   Repo.rollback(:retry)
                 end

                 remember_operation(operation, submitted_payload, result)
                 result

               existing_operation ->
                 if existing_operation.submitted_payload == submitted_payload do
                   Jason.decode!(existing_operation.result)
                 else
                   reject(operation, "operation_id_conflict")
                 end
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, :retry} -> process_identified_operation(operation, submitted_payload)
    end
  end

  defp process_unidentified_operation(operation) do
    case Repo.transaction(
           fn ->
             result = apply_operation(operation)

             if result.status == "rejected" do
               Repo.rollback(result)
             else
               result
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, %{code: "retry"}} -> process_unidentified_operation(operation)
      {:error, result} -> result
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    case operation["type"] do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "cancel_rooms" -> cancel_rooms(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      "transfer_deposit" -> transfer_deposit(operation)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      "start_finance_reporting" -> start_finance_reporting(operation)
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp apply_operation(_operation), do: %{status: "rejected", code: "invalid_operation"}

  defp remember_operation(operation, submitted_payload, result) do
    Repo.insert!(%PartnerOperation{
      operation_id: operation["operation_id"],
      operation_type: operation_type(operation),
      submitted_payload: submitted_payload,
      result: Jason.encode!(result)
    })
  end

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested_value} ->
        {Jason.encode!(key), canonical_json(nested_value)}
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, nested_value} -> key <> ":" <> nested_value end)

    "{" <> entries <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp open_group(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <-
           require_keys(
             operation,
             ~w(group_id guest_id property_id occurred_on arrival_on departure_on rate_plan rooms)
           ),
         :ok <- valid_open_identifiers(operation),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- valid_stay(arrival_on, departure_on),
         :ok <- valid_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- valid_rooms(operation["rooms"]),
         :ok <- group_is_new(operation["group_id"]),
         {:ok, group} <- create_group(operation, booked_on, arrival_on, departure_on, rooms) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
    end
  end

  defp start_finance_reporting(operation) do
    with {:ok, common} <- common_operation(operation),
         {:ok, starts_on} <- reporting_date(operation),
         :ok <- reporting_not_started(),
         :ok <- start_reporting(starts_on) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        starts_on: Date.to_iso8601(starts_on)
      }
    else
      {:rejected, code} -> reject(operation, code)
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(operation, group),
         :ok <- active_group(group),
         :ok <- require_keys(operation, ~w(occurred_on amount_cents)),
         {:ok, _occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- does_not_exceed_outstanding(operation["amount_cents"], group),
         :ok <-
           create_cash_payment(common.operation_id, group.group_id, operation["amount_cents"]),
         :ok <-
           allocate_funding(
             group,
             "cash",
             %{payment_operation_id: common.operation_id},
             operation["amount_cents"]
           ),
         {:ok, group} <- update_group(group, %{}, operation),
         :ok <-
           record_finance_movements(operation, [
             {group.property_id, "received", operation["amount_cents"]}
           ]) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
      {:rejected, code, details} -> reject(operation, code, details)
    end
  end

  defp reschedule_group(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(operation, group),
         :ok <- active_group(group),
         :ok <- require_keys(operation, ~w(occurred_on new_arrival_on)),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- valid_reschedule(new_arrival_on, occurred_on),
         new_departure_on =
           Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on)),
         {:ok, group} <-
           update_group(
             group,
             %{arrival_on: new_arrival_on, departure_on: new_departure_on},
             operation
           ) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(group.arrival_on),
        new_departure_on: Date.to_iso8601(group.departure_on),
        policy_version: policy_version(group),
        refundable_until: refundable_until(group),
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
      {:rejected, code, details} -> reject(operation, code, details)
    end
  end

  defp cancel_group(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(operation, group),
         :ok <- active_group(group),
         :ok <- require_keys(operation, ["occurred_on"]),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         {:ok, refund_method} <- refund_method(operation),
         refundable? <- refundable?(group, occurred_on),
         :ok <- hotel_credit_available(refund_method, refundable?),
         rooms = active_rooms(group),
         {:ok, settlement} <-
           settle_rooms(
             group,
             rooms,
             common.operation_id,
             occurred_on,
             refund_method,
             refundable?
           ),
         :ok <- cancel_room_records(group.group_id, Enum.map(rooms, & &1.room_id)),
         {:ok, group} <- update_group(group, %{status: "cancelled"}, operation),
         :ok <- record_settlement_finance(operation, group.property_id, settlement) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
      {:rejected, code, details} -> reject(operation, code, details)
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(operation, group),
         :ok <- active_group(group),
         :ok <- require_keys(operation, ~w(occurred_on room_ids)),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         {:ok, refund_method} <- refund_method(operation),
         refundable? <- refundable?(group, occurred_on),
         :ok <- hotel_credit_available(refund_method, refundable?),
         {:ok, rooms} <- selected_active_rooms(group, operation["room_ids"]),
         cancelled_room_ids = Enum.map(rooms, & &1.room_id),
         {:ok, settlement} <-
           settle_rooms(
             group,
             rooms,
             common.operation_id,
             occurred_on,
             refund_method,
             refundable?
           ),
         :ok <- cancel_room_records(group.group_id, cancelled_room_ids),
         remaining_rooms = Enum.reject(active_rooms(group), &(&1.room_id in cancelled_room_ids)),
         status = if(remaining_rooms == [], do: "cancelled", else: "active"),
         {:ok, group} <- update_group(group, %{status: status}, operation),
         :ok <- record_settlement_finance(operation, group.property_id, settlement) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        cancelled_room_ids: cancelled_room_ids,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
      {:rejected, code, details} -> reject(operation, code, details)
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(operation, group),
         :ok <- active_group(group),
         :ok <- require_keys(operation, ~w(occurred_on amount_cents)),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- does_not_exceed_outstanding(operation["amount_cents"], group),
         :ok <- consume_hotel_credit(group, operation["amount_cents"], occurred_on),
         {:ok, group} <- update_group(group, %{}, operation) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
      {:rejected, code, details} -> reject(operation, code, details)
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ~w(source_group_id destination_group_id amount_cents)),
         {:ok, source_group} <- fetch_transfer_group(operation["source_group_id"]),
         {:ok, destination_group} <- fetch_transfer_group(operation["destination_group_id"]),
         :ok <- check_transfer_revision(operation, source_group, "expected_revision"),
         :ok <-
           check_transfer_revision(
             operation,
             destination_group,
             "destination_expected_revision"
           ),
         :ok <- valid_transfer_groups(source_group, destination_group),
         :ok <- active_transfer_group(source_group),
         :ok <- active_transfer_group(destination_group),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- transfer_within_held_funding(operation["amount_cents"], source_group),
         :ok <- transfer_within_outstanding(operation["amount_cents"], destination_group),
         {:ok, cash_cents} <-
           move_held_funding(source_group, destination_group, operation["amount_cents"]),
         {:ok, source_group} <- update_group(source_group, %{}, operation),
         {:ok, destination_group} <- update_group(destination_group, %{}, %{}),
         :ok <-
           record_finance_movements(operation, [
             {source_group.property_id, "transferred_out", cash_cents},
             {destination_group.property_id, "transferred_in", cash_cents}
           ]) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        source_group_id: source_group.group_id,
        destination_group_id: destination_group.group_id,
        amount_cents: operation["amount_cents"],
        source_outstanding_deposit_cents: outstanding_deposit(source_group),
        destination_outstanding_deposit_cents: outstanding_deposit(destination_group),
        source_revision: source_group.revision,
        destination_revision: destination_group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
      {:rejected, code, details} -> reject(operation, code, details)
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ~w(payment_operation_id amount_cents)),
         {:ok, payment} <- reducible_payment(operation["payment_operation_id"]),
         {:ok, group} <- fetch_group(payment.group_id),
         :ok <- check_revision(operation, group),
         :ok <- valid_amount(operation["amount_cents"]),
         held_cents = payment_held(payment.operation_id),
         :ok <- payment_has_held_cash(held_cents),
         :ok <- reduction_within_held(operation["amount_cents"], held_cents),
         {:ok, changed_group_ids, held_by_group} <-
           remove_payment_allocations(payment.operation_id, operation["amount_cents"]),
         :ok <- increment_payment(payment.operation_id, :reduced_cents, operation["amount_cents"]),
         {:ok, group} <- update_funding_groups(group, changed_group_ids, operation),
         :ok <-
           record_finance_movements(
             operation,
             held_by_group
             |> Enum.map(fn {group_id, amount_cents} ->
               {Repo.get!(Group, group_id).property_id, "reduced", amount_cents}
             end)
           ) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        payment_operation_id: payment.operation_id,
        group_id: group.group_id,
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      }
    else
      {:rejected, code} ->
        reject(operation, code)

      {:rejected, code, details} ->
        reject_for_group(operation, code, payment_group_id(operation), details)
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ["payment_operation_id"]),
         {:ok, payment} <- chargeable_payment(operation["payment_operation_id"]),
         {:ok, group} <- fetch_group(payment.group_id),
         :ok <- check_revision(operation, group),
         charged_back_cents = payment.recorded_cents - payment.reduced_cents,
         :ok <- valid_chargeback(payment, charged_back_cents),
         dispositions = payment_dispositions(payment.operation_id),
         {:ok, changed_group_ids, held_by_group} <-
           remove_payment_allocations(payment.operation_id, payment_held(payment.operation_id)),
         {:ok, revoked_cents} <- revoke_payment_entitlements(payment.operation_id, operation),
         :ok <- charge_back_payment_record(payment, charged_back_cents),
         :ok <- delete_payment_dispositions(payment.operation_id),
         {:ok, group} <- update_funding_groups(group, changed_group_ids, operation),
         :ok <-
           record_chargeback_finance(operation, held_by_group, dispositions, revoked_cents) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        payment_operation_id: payment.operation_id,
        group_id: group.group_id,
        charged_back_cents: charged_back_cents,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      }
    else
      {:rejected, code} ->
        reject(operation, code)

      {:rejected, code, details} ->
        reject_for_group(operation, code, payment_group_id(operation), details)
    end
  end

  defp common_operation(operation) do
    with :ok <- require_keys(operation, ~w(operation_id type)),
         true <- is_binary(operation["operation_id"]) do
      {:ok, %{operation_id: operation["operation_id"]}}
    else
      _ -> {:rejected, "invalid_operation"}
    end
  end

  defp require_keys(operation, keys) do
    if Enum.all?(keys, &Map.has_key?(operation, &1)),
      do: :ok,
      else: {:rejected, "invalid_operation"}
  end

  defp parse_date(value, error_code \\ "invalid_stay")

  defp parse_date(value, error_code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:rejected, error_code}
    end
  end

  defp parse_date(_value, error_code), do: {:rejected, error_code}

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:rejected, "invalid_stay"}
  end

  defp valid_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp valid_rate_plan(_rate_plan), do: {:rejected, "invalid_rate_plan"}

  defp valid_open_identifiers(operation) do
    if Enum.all?(~w(group_id guest_id property_id), &is_binary(operation[&1])),
      do: :ok,
      else: {:rejected, "invalid_operation"}
  end

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    with true <- Enum.all?(rooms, &valid_room?/1),
         room_ids <- Enum.map(rooms, & &1["room_id"]),
         true <- length(room_ids) == length(Enum.uniq(room_ids)) do
      {:ok, rooms}
    else
      _ -> {:rejected, "invalid_rooms"}
    end
  end

  defp valid_rooms(_rooms), do: {:rejected, "invalid_rooms"}

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}) do
    is_binary(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents >= 0
  end

  defp valid_room?(_room), do: false

  defp group_is_new(group_id) when is_binary(group_id) do
    if Repo.get(Group, group_id), do: {:rejected, "group_already_exists"}, else: :ok
  end

  defp group_is_new(_group_id), do: {:rejected, "invalid_operation"}

  defp create_group(operation, booked_on, arrival_on, departure_on, rooms) do
    nights = Date.diff(departure_on, arrival_on)

    room_data =
      Enum.map(rooms, fn room ->
        lodging_total_cents = nights * room["nightly_rate_cents"]

        %{
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"],
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents:
            room_deposit(room["nightly_rate_cents"], nights, operation["rate_plan"])
        }
      end)

    group = %Group{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      policy_version: policy_for(operation["rate_plan"], booked_on),
      status: "active",
      revision: 1,
      lodging_total_cents: Enum.sum_by(room_data, & &1.lodging_total_cents),
      deposit_due_cents: Enum.sum_by(room_data, & &1.deposit_due_cents),
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      cash_converted_to_credit_cents: 0
    }

    with {:ok, group} <- Repo.insert(group),
         :ok <- create_rooms(group.group_id, room_data) do
      {:ok, group}
    else
      {:error, _changeset} -> {:rejected, "group_already_exists"}
      {:rejected, _code} = rejection -> rejection
    end
  end

  defp create_rooms(group_id, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      Repo.insert!(%Room{
        group_id: group_id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        lodging_total_cents: room.lodging_total_cents,
        deposit_due_cents: room.deposit_due_cents,
        status: "active",
        position: position
      })
    end)

    :ok
  end

  defp room_deposit(nightly_rate_cents, nights, "flexible"),
    do: div(nightly_rate_cents * nights + 2, 5)

  defp room_deposit(nightly_rate_cents, nights, "advance_purchase"),
    do: nightly_rate_cents * nights

  defp fetch_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:rejected, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp fetch_group(_group_id), do: {:rejected, "invalid_operation"}

  defp fetch_transfer_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:rejected, "group_not_found", %{group_id: group_id}}
      group -> {:ok, group}
    end
  end

  defp fetch_transfer_group(_group_id), do: {:rejected, "invalid_operation"}

  defp check_revision(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:rejected, "stale_revision",
       %{expected_revision: operation["expected_revision"], actual_revision: group.revision}}
    else
      :ok
    end
  end

  defp check_transfer_revision(operation, group, field) do
    if Map.has_key?(operation, field) and operation[field] != group.revision do
      {:rejected, "stale_revision",
       %{
         group_id: group.group_id,
         expected_revision: operation[field],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp active_group(%Group{status: "active"}), do: :ok
  defp active_group(_group), do: {:rejected, "group_not_active"}

  defp valid_transfer_groups(source_group, destination_group) do
    if source_group.group_id != destination_group.group_id and
         source_group.guest_id == destination_group.guest_id do
      :ok
    else
      {:rejected, "invalid_transfer"}
    end
  end

  defp active_transfer_group(%Group{status: "active"}), do: :ok

  defp active_transfer_group(group),
    do: {:rejected, "group_not_active", %{group_id: group.group_id}}

  defp valid_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0, do: :ok
  defp valid_amount(_amount_cents), do: {:rejected, "invalid_amount"}

  defp does_not_exceed_outstanding(amount_cents, group) do
    if amount_cents <= outstanding_deposit(group),
      do: :ok,
      else: {:rejected, "payment_exceeds_outstanding"}
  end

  defp transfer_within_held_funding(amount_cents, group) do
    if amount_cents <= held_funding(group.group_id),
      do: :ok,
      else: {:rejected, "transfer_exceeds_held_funding"}
  end

  defp transfer_within_outstanding(amount_cents, group) do
    if amount_cents <= outstanding_deposit(group),
      do: :ok,
      else: {:rejected, "transfer_exceeds_outstanding"}
  end

  defp valid_reschedule(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:rejected, "invalid_stay"}
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:rejected, "invalid_operation"}
    end
  end

  defp hotel_credit_available("hotel_credit", false),
    do: {:rejected, "refund_method_not_available"}

  defp hotel_credit_available(_refund_method, _refundable?), do: :ok

  defp refundable?(group, occurred_on) do
    case refundable_until_date(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp policy_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_version(%Group{policy_version: policy_version})
       when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"],
       do: policy_version

  defp policy_version(group), do: policy_for(group.rate_plan, group.booked_on)
  defp refundable_until(group), do: group |> refundable_until_date() |> date_string()

  defp refundable_until_date(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp date_string(nil), do: nil
  defp date_string(date), do: Date.to_iso8601(date)

  defp create_cash_payment(operation_id, group_id, amount_cents) do
    case Repo.insert(%CashPayment{
           operation_id: operation_id,
           group_id: group_id,
           recorded_cents: amount_cents,
           refunded_cents: 0,
           retained_cents: 0,
           converted_to_credit_cents: 0,
           reduced_cents: 0,
           charged_back_cents: 0,
           participated_in_transfer: false
         }) do
      {:ok, _payment} -> :ok
      {:error, _changeset} -> {:rejected, "retry"}
    end
  end

  defp allocate_funding(group, funding_kind, source, amount_cents) do
    {remaining_cents, _} =
      Enum.reduce_while(active_room_states(group), {amount_cents, 0}, fn room,
                                                                         {remaining_cents, _} ->
        applied_cents =
          min(
            room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents,
            remaining_cents
          )

        if applied_cents > 0 do
          Repo.insert!(%RoomFundingAllocation{
            group_id: group.group_id,
            room_id: room.room_id,
            funding_kind: funding_kind,
            payment_operation_id: Map.get(source, :payment_operation_id),
            credit_lot_id: Map.get(source, :credit_lot_id),
            amount_cents: applied_cents
          })
        end

        if applied_cents == remaining_cents do
          {:halt, {0, 0}}
        else
          {:cont, {remaining_cents - applied_cents, 0}}
        end
      end)

    if remaining_cents == 0, do: :ok, else: {:rejected, "retry"}
  end

  defp move_held_funding(source_group, destination_group, amount_cents) do
    source_group
    |> source_funding_allocations()
    |> Enum.reduce_while({amount_cents, MapSet.new(), 0}, fn allocation,
                                                             {remaining_cents, payment_ids,
                                                              cash_cents} ->
      moved_cents = min(allocation.amount_cents, remaining_cents)

      with :ok <- remove_funding_allocation(allocation, moved_cents),
           :ok <-
             allocate_funding(
               destination_group,
               allocation.funding_kind,
               %{
                 payment_operation_id: allocation.payment_operation_id,
                 credit_lot_id: allocation.credit_lot_id
               },
               moved_cents
             ) do
        payment_ids =
          if allocation.funding_kind == "cash" and is_binary(allocation.payment_operation_id) do
            MapSet.put(payment_ids, allocation.payment_operation_id)
          else
            payment_ids
          end

        cash_cents =
          if allocation.funding_kind == "cash" do
            cash_cents + moved_cents
          else
            cash_cents
          end

        if moved_cents == remaining_cents do
          {:halt, {0, payment_ids, cash_cents}}
        else
          {:cont, {remaining_cents - moved_cents, payment_ids, cash_cents}}
        end
      else
        rejection -> {:halt, rejection}
      end
    end)
    |> case do
      {0, payment_ids, cash_cents} ->
        case mark_payments_transferred(payment_ids) do
          :ok -> {:ok, cash_cents}
          rejection -> rejection
        end

      {_remaining_cents, _payment_ids, _cash_cents} ->
        {:rejected, "retry"}

      rejection ->
        rejection
    end
  end

  defp source_funding_allocations(group) do
    RoomFundingAllocation
    |> join(:inner, [allocation], room in Room,
      on: room.group_id == allocation.group_id and room.room_id == allocation.room_id
    )
    |> where(
      [allocation, room],
      allocation.group_id == ^group.group_id and room.status == "active"
    )
    |> order_by([allocation], desc: allocation.id)
    |> select([allocation], allocation)
    |> Repo.all()
  end

  defp remove_funding_allocation(allocation, amount_cents)
       when amount_cents == allocation.amount_cents do
    case Repo.delete(allocation) do
      {:ok, _allocation} -> :ok
      {:error, _changeset} -> {:rejected, "retry"}
    end
  end

  defp remove_funding_allocation(allocation, amount_cents) do
    case Repo.update_all(
           from(current_allocation in RoomFundingAllocation,
             where:
               current_allocation.id == ^allocation.id and
                 current_allocation.amount_cents >= ^amount_cents
           ),
           inc: [amount_cents: -amount_cents]
         ) do
      {1, _} -> :ok
      {0, _} -> {:rejected, "retry"}
    end
  end

  defp mark_payments_transferred(payment_ids) do
    payment_ids = MapSet.to_list(payment_ids)

    if payment_ids == [] do
      :ok
    else
      {count, _} =
        Repo.update_all(
          from(payment in CashPayment, where: payment.operation_id in ^payment_ids),
          set: [participated_in_transfer: true]
        )

      if count == length(payment_ids), do: :ok, else: {:rejected, "retry"}
    end
  end

  defp consume_hotel_credit(group, amount_cents, occurred_on) do
    lots = available_lots(group.guest_id, occurred_on)

    with :ok <- enough_credit(lots, amount_cents),
         {:ok, allocations} <- credit_allocations(lots, amount_cents),
         :ok <- decrement_lots(allocations, occurred_on),
         :ok <- allocate_credit_funding(group, allocations) do
      :ok
    end
  end

  defp enough_credit(lots, amount_cents) do
    if Enum.sum_by(lots, & &1.remaining_cents) >= amount_cents,
      do: :ok,
      else: {:rejected, "insufficient_credit"}
  end

  defp credit_allocations(lots, amount_cents) do
    {remaining_cents, allocations} =
      Enum.reduce_while(lots, {amount_cents, []}, fn lot, {remaining_cents, allocations} ->
        applied_cents = min(lot.remaining_cents, remaining_cents)

        if applied_cents == remaining_cents do
          {:halt, {0, [{lot, applied_cents} | allocations]}}
        else
          {:cont, {remaining_cents - applied_cents, [{lot, applied_cents} | allocations]}}
        end
      end)

    if remaining_cents == 0,
      do: {:ok, Enum.reverse(allocations)},
      else: {:rejected, "insufficient_credit"}
  end

  defp decrement_lots(allocations, occurred_on) do
    Enum.reduce_while(allocations, :ok, fn {lot, applied_cents}, :ok ->
      query =
        from current_lot in CreditLot,
          where:
            current_lot.id == ^lot.id and current_lot.remaining_cents >= ^applied_cents and
              current_lot.expires_on > ^occurred_on

      case Repo.update_all(query, inc: [remaining_cents: -applied_cents]) do
        {1, _} ->
          :ok = set_credit_expiry_schedule(Repo.get!(CreditLot, lot.id))
          {:cont, :ok}

        {0, _} ->
          {:halt, {:rejected, "retry"}}
      end
    end)
  end

  defp allocate_credit_funding(group, allocations) do
    Enum.reduce_while(allocations, :ok, fn {lot, amount_cents}, :ok ->
      case allocate_funding(group, "credit", %{credit_lot_id: lot.id}, amount_cents) do
        :ok -> {:cont, :ok}
        rejection -> {:halt, rejection}
      end
    end)
  end

  defp selected_active_rooms(group, room_ids)
       when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &is_binary/1) and length(room_ids) == length(Enum.uniq(room_ids)) do
      rooms =
        Room
        |> where(
          [room],
          room.group_id == ^group.group_id and room.status == "active" and
            room.room_id in ^room_ids
        )
        |> order_by([room], asc: room.position)
        |> Repo.all()

      if length(rooms) == length(room_ids), do: {:ok, rooms}, else: {:rejected, "invalid_rooms"}
    else
      {:rejected, "invalid_rooms"}
    end
  end

  defp selected_active_rooms(_group, _room_ids), do: {:rejected, "invalid_rooms"}

  defp settle_rooms(group, rooms, operation_id, occurred_on, refund_method, refundable?) do
    room_ids = Enum.map(rooms, & &1.room_id)
    allocations = funding_allocations(group.group_id, room_ids)
    cash_allocations = Enum.filter(allocations, &(&1.funding_kind == "cash"))
    credit_allocations = Enum.filter(allocations, &(&1.funding_kind == "credit"))
    cash_cents = Enum.sum_by(cash_allocations, & &1.amount_cents)

    {refunded_cents, retained_cents, credit_issued_cents, credit_lot} =
      case {refund_method, refundable?} do
        {"cash", true} ->
          :ok = reclassify_cash(group.group_id, cash_allocations, :refunded_cents)
          {cash_cents, 0, 0, nil}

        {"hotel_credit", true} ->
          :ok = reclassify_cash(group.group_id, cash_allocations, :converted_to_credit_cents)

          {:ok, issued_cents, credit_lot} =
            issue_hotel_credit(group, operation_id, occurred_on, cash_allocations)

          {0, 0, issued_cents, credit_lot}

        {_method, false} ->
          :ok = reclassify_cash(group.group_id, cash_allocations, :retained_cents)
          {0, cash_cents, 0, nil}
      end

    credit_settlement = settle_credit_allocations(credit_allocations, occurred_on, refundable?)
    delete_funding_allocations(group.group_id, room_ids)

    {:ok,
     %{
       cash_cents: cash_cents,
       refunded_cents: refunded_cents,
       retained_cents: retained_cents,
       credit_issued_cents: credit_issued_cents,
       credit_lot: credit_lot,
       credit_consumed_cents:
         if(refundable?, do: 0, else: Enum.sum_by(credit_allocations, & &1.amount_cents)),
       absorbed_cents: credit_settlement.absorbed_cents,
       expired_cents: credit_settlement.expired_cents
     }}
  end

  defp reclassify_cash(group_id, allocations, payment_field) do
    property_id = Repo.get!(Group, group_id).property_id

    {legacy_cents, payments} =
      Enum.reduce(allocations, {0, %{}}, fn allocation, {legacy_cents, payments} ->
        case allocation.payment_operation_id do
          nil ->
            {legacy_cents + allocation.amount_cents, payments}

          operation_id ->
            {legacy_cents,
             Map.update(
               payments,
               operation_id,
               allocation.amount_cents,
               &(&1 + allocation.amount_cents)
             )}
        end
      end)

    if legacy_cents > 0 do
      Repo.update_all(from(group in Group, where: group.group_id == ^group_id),
        inc: [{legacy_payment_field(payment_field), legacy_cents}]
      )
    end

    Enum.each(payments, fn {operation_id, amount_cents} ->
      increment_payment(operation_id, payment_field, amount_cents)
      record_payment_disposition(operation_id, property_id, payment_field, amount_cents)
    end)

    :ok
  end

  defp legacy_payment_field(:refunded_cents), do: :refunded_cents
  defp legacy_payment_field(:retained_cents), do: :retained_cents
  defp legacy_payment_field(:converted_to_credit_cents), do: :cash_converted_to_credit_cents

  defp record_payment_disposition(_operation_id, _property_id, _payment_field, 0), do: :ok

  defp record_payment_disposition(operation_id, property_id, payment_field, amount_cents) do
    kind =
      case payment_field do
        :refunded_cents -> "refunded"
        :retained_cents -> "retained"
        :converted_to_credit_cents -> "converted_to_credit"
      end

    Repo.insert!(%CashPaymentDisposition{
      payment_operation_id: operation_id,
      property_id: property_id,
      kind: kind,
      amount_cents: amount_cents
    })

    :ok
  end

  defp payment_dispositions(operation_id) do
    CashPaymentDisposition
    |> where([disposition], disposition.payment_operation_id == ^operation_id)
    |> Repo.all()
  end

  defp delete_payment_dispositions(operation_id) do
    Repo.delete_all(
      from(disposition in CashPaymentDisposition,
        where: disposition.payment_operation_id == ^operation_id
      )
    )

    :ok
  end

  defp issue_hotel_credit(_group, _operation_id, _occurred_on, []), do: {:ok, 0, nil}

  defp issue_hotel_credit(group, operation_id, occurred_on, cash_allocations) do
    cash_cents = Enum.sum_by(cash_allocations, & &1.amount_cents)
    credit_issued_cents = cash_cents + percentage_bonus(cash_cents)

    with {:ok, lot} <-
           Repo.insert(%CreditLot{
             guest_id: group.guest_id,
             source_operation_id: operation_id,
             remaining_cents: credit_issued_cents,
             unrecovered_clawback_cents: 0,
             # Credit is usable for the 365 days following cancellation and expires the next day.
             expires_on: Date.add(occurred_on, 366)
           }),
         :ok <- create_credit_contributions(lot.id, cash_sources(cash_allocations)) do
      :ok = set_credit_expiry_schedule(lot)
      {:ok, credit_issued_cents, lot}
    else
      {:error, _changeset} -> {:rejected, "retry"}
      {:rejected, _code} = rejection -> rejection
    end
  end

  defp cash_sources(allocations) do
    allocations
    |> Enum.reduce(%{}, fn allocation, sources ->
      key = allocation.payment_operation_id

      Map.update(sources, key, {allocation.id, allocation.amount_cents}, fn {first_id,
                                                                             amount_cents} ->
        {min(first_id, allocation.id), amount_cents + allocation.amount_cents}
      end)
    end)
    |> Enum.map(fn {operation_id, {first_id, amount_cents}} ->
      {operation_id, first_id, amount_cents}
    end)
    |> Enum.sort_by(fn {operation_id, first_id, _amount_cents} ->
      commit_order =
        case operation_id do
          nil -> 0
          _ -> Repo.get_by!(PartnerOperation, operation_id: operation_id).id
        end

      {if(is_nil(operation_id), do: 0, else: 1), commit_order, first_id}
    end)
  end

  defp create_credit_contributions(lot_id, sources) do
    Enum.reduce_while(sources, 0, fn {payment_operation_id, _first_id, cash_amount_cents},
                                     prior_cents ->
      through_cents = prior_cents + cash_amount_cents
      entitlement_cents = credit_value(through_cents) - credit_value(prior_cents)

      case Repo.insert(%CreditLotContribution{
             credit_lot_id: lot_id,
             payment_operation_id: payment_operation_id,
             cash_amount_cents: cash_amount_cents,
             entitlement_cents: entitlement_cents
           }) do
        {:ok, _contribution} -> {:cont, through_cents}
        {:error, _changeset} -> {:halt, {:rejected, "retry"}}
      end
    end)
    |> case do
      {:rejected, _code} = rejection -> rejection
      _total -> :ok
    end
  end

  defp percentage_bonus(cash_cents), do: div(cash_cents + 5, 10)
  defp credit_value(cash_cents), do: cash_cents + percentage_bonus(cash_cents)

  defp settle_credit_allocations(allocations, occurred_on, true) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.reduce(%{absorbed_cents: 0, expired_cents: 0}, fn {lot_id, lot_allocations}, totals ->
      settlement =
        restore_credit_lot(lot_id, Enum.sum_by(lot_allocations, & &1.amount_cents), occurred_on)

      %{
        absorbed_cents: totals.absorbed_cents + settlement.absorbed_cents,
        expired_cents: totals.expired_cents + settlement.expired_cents
      }
    end)
  end

  defp settle_credit_allocations(_allocations, _occurred_on, false),
    do: %{absorbed_cents: 0, expired_cents: 0}

  defp restore_credit_lot(lot_id, amount_cents, occurred_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed_cents = min(lot.unrecovered_clawback_cents, amount_cents)
    restored_cents = amount_cents - absorbed_cents

    changes = [unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed_cents]

    available_cents =
      if Date.compare(lot.expires_on, occurred_on) == :gt, do: restored_cents, else: 0

    changes =
      if available_cents > 0,
        do: [{:remaining_cents, lot.remaining_cents + available_cents} | changes],
        else: changes

    Repo.update_all(from(current_lot in CreditLot, where: current_lot.id == ^lot_id),
      set: changes
    )

    if available_cents > 0 do
      :ok = set_credit_expiry_schedule(Repo.get!(CreditLot, lot_id))
    end

    %{absorbed_cents: absorbed_cents, expired_cents: restored_cents - available_cents}
  end

  defp cancel_room_records(group_id, room_ids) do
    {count, _} =
      Repo.update_all(
        from(room in Room,
          where:
            room.group_id == ^group_id and room.room_id in ^room_ids and room.status == "active"
        ),
        set: [status: "cancelled"]
      )

    if count == length(room_ids), do: :ok, else: {:rejected, "retry"}
  end

  defp funding_allocations(group_id, room_ids) do
    RoomFundingAllocation
    |> where([allocation], allocation.group_id == ^group_id and allocation.room_id in ^room_ids)
    |> order_by([allocation], asc: allocation.id)
    |> Repo.all()
  end

  defp delete_funding_allocations(group_id, room_ids) do
    Repo.delete_all(
      from(allocation in RoomFundingAllocation,
        where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids
      )
    )

    :ok
  end

  defp reducible_payment(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> {:rejected, "operation_not_found"}
      _operation -> payment_or_rejection(operation_id, "payment_not_reducible")
    end
  end

  defp reducible_payment(_operation_id), do: {:rejected, "operation_not_found"}

  defp chargeable_payment(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> {:rejected, "operation_not_found"}
      _operation -> payment_or_rejection(operation_id, "payment_not_chargeable")
    end
  end

  defp chargeable_payment(_operation_id), do: {:rejected, "operation_not_found"}

  defp payment_or_rejection(operation_id, code) do
    case Repo.get(CashPayment, operation_id) do
      nil -> {:rejected, code}
      payment -> {:ok, payment}
    end
  end

  defp payment_group_id(%{"payment_operation_id" => operation_id}) do
    case Repo.get(CashPayment, operation_id) do
      nil -> nil
      payment -> payment.group_id
    end
  end

  defp payment_group_id(_operation), do: nil

  defp payment_has_held_cash(held_cents) when held_cents > 0, do: :ok
  defp payment_has_held_cash(_held_cents), do: {:rejected, "payment_not_reducible"}

  defp reduction_within_held(amount_cents, held_cents) when amount_cents <= held_cents, do: :ok

  defp reduction_within_held(_amount_cents, _held_cents),
    do: {:rejected, "reduction_exceeds_held_cash"}

  defp valid_chargeback(payment, charged_back_cents) do
    if charged_back_cents > 0 and payment.charged_back_cents == 0,
      do: :ok,
      else: {:rejected, "payment_not_chargeable"}
  end

  defp payment_held(operation_id) do
    RoomFundingAllocation
    |> join(:inner, [allocation], room in Room,
      on: room.group_id == allocation.group_id and room.room_id == allocation.room_id
    )
    |> where(
      [allocation, room],
      allocation.payment_operation_id == ^operation_id and allocation.funding_kind == "cash" and
        room.status == "active"
    )
    |> select([allocation], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp held_funding(group_id) do
    RoomFundingAllocation
    |> join(:inner, [allocation], room in Room,
      on: room.group_id == allocation.group_id and room.room_id == allocation.room_id
    )
    |> where([allocation, room], allocation.group_id == ^group_id and room.status == "active")
    |> select([allocation], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp remove_payment_allocations(_operation_id, 0), do: {:ok, [], []}

  defp remove_payment_allocations(operation_id, amount_cents) do
    allocations =
      RoomFundingAllocation
      |> join(:inner, [allocation], room in Room,
        on: room.group_id == allocation.group_id and room.room_id == allocation.room_id
      )
      |> where(
        [allocation, room],
        allocation.payment_operation_id == ^operation_id and allocation.funding_kind == "cash" and
          room.status == "active"
      )
      |> order_by([allocation], desc: allocation.id)
      |> select([allocation], allocation)
      |> Repo.all()

    {remaining_cents, changed_group_ids, held_by_group} =
      Enum.reduce_while(allocations, {amount_cents, MapSet.new(), %{}}, fn allocation,
                                                                           {remaining_cents,
                                                                            changed_group_ids,
                                                                            held_by_group} ->
        removed_cents = min(allocation.amount_cents, remaining_cents)

        if removed_cents == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update_all(
            from(current_allocation in RoomFundingAllocation,
              where: current_allocation.id == ^allocation.id
            ),
            inc: [amount_cents: -removed_cents]
          )
        end

        changed_group_ids = MapSet.put(changed_group_ids, allocation.group_id)

        held_by_group =
          Map.update(held_by_group, allocation.group_id, removed_cents, &(&1 + removed_cents))

        if removed_cents == remaining_cents do
          {:halt, {0, changed_group_ids, held_by_group}}
        else
          {:cont, {remaining_cents - removed_cents, changed_group_ids, held_by_group}}
        end
      end)

    if remaining_cents == 0,
      do: {:ok, MapSet.to_list(changed_group_ids), Map.to_list(held_by_group)},
      else: {:rejected, "retry"}
  end

  defp increment_payment(operation_id, field, amount_cents) do
    {count, _} =
      Repo.update_all(
        from(payment in CashPayment, where: payment.operation_id == ^operation_id),
        inc: [{field, amount_cents}]
      )

    if count == 1, do: :ok, else: {:rejected, "retry"}
  end

  defp charge_back_payment_record(payment, charged_back_cents) do
    {count, _} =
      Repo.update_all(
        from(current_payment in CashPayment,
          where: current_payment.operation_id == ^payment.operation_id
        ),
        set: [
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: payment.charged_back_cents + charged_back_cents
        ]
      )

    if count == 1, do: :ok, else: {:rejected, "retry"}
  end

  defp revoke_payment_entitlements(operation_id, operation) do
    revoked_cents =
      CreditLotContribution
      |> where([contribution], contribution.payment_operation_id == ^operation_id)
      |> Repo.all()
      |> Enum.sum_by(fn contribution ->
        revoke_lot_entitlement(
          contribution.credit_lot_id,
          contribution.entitlement_cents,
          operation
        )
      end)

    {:ok, revoked_cents}
  end

  defp revoke_lot_entitlement(lot_id, entitlement_cents, operation) do
    lot = Repo.get!(CreditLot, lot_id)

    revoked_cents =
      if Date.compare(lot.expires_on, credit_evaluation_date(operation)) == :gt do
        min(lot.remaining_cents, entitlement_cents)
      else
        0
      end

    unrecovered_cents = entitlement_cents - revoked_cents
    reportable_revocation? = reportable_credit_revocation?(lot_id, operation)

    Repo.update_all(
      from(current_lot in CreditLot, where: current_lot.id == ^lot_id),
      set: [remaining_cents: lot.remaining_cents - revoked_cents],
      inc: [unrecovered_clawback_cents: unrecovered_cents]
    )

    if reportable_revocation? do
      :ok = set_credit_expiry_schedule(Repo.get!(CreditLot, lot_id))
      revoked_cents
    else
      0
    end
  end

  defp update_funding_groups(addressed_group, changed_group_ids, operation) do
    group_ids = Enum.uniq([addressed_group.group_id | changed_group_ids])

    Enum.reduce_while(group_ids, {:ok, nil}, fn group_id, {:ok, addressed_group_after} ->
      group =
        if group_id == addressed_group.group_id,
          do: addressed_group,
          else: Repo.get!(Group, group_id)

      update_operation = if group_id == addressed_group.group_id, do: operation, else: %{}

      case update_group(group, %{}, update_operation) do
        {:ok, updated_group} ->
          addressed_group_after =
            if group_id == addressed_group.group_id,
              do: updated_group,
              else: addressed_group_after

          {:cont, {:ok, addressed_group_after}}

        rejection ->
          {:halt, rejection}
      end
    end)
  end

  defp update_group(group, changes, operation) do
    changes =
      changes
      |> Map.put(:revision, group.revision + 1)
      |> Map.put(:updated_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))

    query =
      from(current_group in Group,
        where:
          current_group.group_id == ^group.group_id and current_group.revision == ^group.revision
      )

    case Repo.update_all(query, set: Map.to_list(changes)) do
      {1, _} ->
        {:ok, Repo.get!(Group, group.group_id)}

      {0, _} ->
        current_group = Repo.get!(Group, group.group_id)

        if Map.has_key?(operation, "expected_revision") do
          {:rejected, "stale_revision",
           %{
             expected_revision: operation["expected_revision"],
             actual_revision: current_group.revision
           }}
        else
          {:rejected, "retry"}
        end
    end
  end

  defp outstanding_deposit(group) do
    group
    |> active_room_states()
    |> Enum.sum_by(fn room ->
      room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    end)
  end

  defp active_rooms(group) do
    Room
    |> where([room], room.group_id == ^group.group_id and room.status == "active")
    |> order_by([room], asc: room.position)
    |> Repo.all()
  end

  defp active_room_states(group) do
    group
    |> room_states()
    |> Enum.filter(&(&1.status == "active"))
  end

  defp room_states(group) do
    rooms =
      Room
      |> where([room], room.group_id == ^group.group_id)
      |> order_by([room], asc: room.position)
      |> Repo.all()

    allocations =
      RoomFundingAllocation
      |> where([allocation], allocation.group_id == ^group.group_id)
      |> Repo.all()
      |> Enum.group_by(& &1.room_id)

    Enum.map(rooms, fn room ->
      room_allocations = Map.get(allocations, room.room_id, [])

      %{
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        lodging_total_cents: room.lodging_total_cents,
        deposit_due_cents: room.deposit_due_cents,
        status: room.status,
        cash_paid_cents:
          room_allocations
          |> Enum.filter(&(&1.funding_kind == "cash"))
          |> Enum.sum_by(& &1.amount_cents),
        credit_paid_cents:
          room_allocations
          |> Enum.filter(&(&1.funding_kind == "credit"))
          |> Enum.sum_by(& &1.amount_cents)
      }
    end)
  end

  defp group_response(group) do
    rooms = room_states(group)
    active_rooms = Enum.filter(rooms, &(&1.status == "active"))
    cash_paid_cents = Enum.sum_by(active_rooms, & &1.cash_paid_cents)
    credit_paid_cents = Enum.sum_by(active_rooms, & &1.credit_paid_cents)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      revision: group.revision,
      rooms:
        Enum.map(rooms, fn room ->
          Map.take(room, [
            :room_id,
            :nightly_rate_cents,
            :status,
            :lodging_total_cents,
            :deposit_due_cents,
            :cash_paid_cents,
            :credit_paid_cents
          ])
        end),
      lodging_total_cents: Enum.sum_by(active_rooms, & &1.lodging_total_cents),
      deposit_due_cents: Enum.sum_by(active_rooms, & &1.deposit_due_cents),
      deposit_paid_cents: cash_paid_cents + credit_paid_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      outstanding_deposit_cents:
        Enum.sum_by(active_rooms, fn room ->
          room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        end)
    }
  end

  defp payment_response(payment) do
    statement = %{
      payment_operation_id: payment.operation_id,
      original_group_id: payment.group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: payment_held(payment.operation_id),
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_to_credit_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }

    if payment.participated_in_transfer do
      Map.put(statement, :held_by_group, payment_held_by_group(payment.operation_id))
    else
      statement
    end
  end

  defp payment_held_by_group(operation_id) do
    RoomFundingAllocation
    |> join(:inner, [allocation], room in Room,
      on: room.group_id == allocation.group_id and room.room_id == allocation.room_id
    )
    |> where(
      [allocation, room],
      allocation.payment_operation_id == ^operation_id and allocation.funding_kind == "cash" and
        room.status == "active"
    )
    |> group_by([allocation], allocation.group_id)
    |> order_by([allocation], asc: allocation.group_id)
    |> select([allocation], {allocation.group_id, sum(allocation.amount_cents)})
    |> Repo.all()
    |> Enum.map(fn {group_id, amount_cents} ->
      %{group_id: group_id, amount_cents: amount_cents}
    end)
  end

  defp reporting_date(operation) do
    case Map.get(operation, "starts_on") do
      value when is_binary(value) -> parse_date(value, "invalid_reporting_date")
      _ -> {:rejected, "invalid_reporting_date"}
    end
  end

  defp reporting_start, do: Repo.get(FinanceReportingStart, 1)

  defp reporting_not_started do
    if reporting_start(), do: {:rejected, "reporting_already_started"}, else: :ok
  end

  defp start_reporting(starts_on) do
    start =
      Repo.insert!(%FinanceReportingStart{
        id: 1,
        starts_on: starts_on,
        opening_credit_liability_cents: credit_liability(starts_on)
      })

    cash_held_by_property()
    |> Enum.each(fn {property_id, opening_held_cents} ->
      Repo.insert!(%FinanceCashOpening{
        reporting_start_id: start.id,
        property_id: property_id,
        opening_held_cents: opening_held_cents
      })
    end)

    CreditLot
    |> where([lot], lot.remaining_cents > 0 and lot.expires_on > ^starts_on)
    |> Repo.all()
    |> Enum.each(&set_credit_expiry_schedule(&1, start))

    :ok
  end

  defp record_finance_movements(operation, cash_movements, credit_movements \\ []) do
    case reporting_start() do
      nil ->
        :ok

      start ->
        posting_on = reporting_posting_date(operation, start.starts_on)

        Enum.each(cash_movements, fn {property_id, kind, amount_cents} ->
          insert_finance_posting(start, operation, posting_on, property_id, kind, amount_cents)
        end)

        Enum.each(credit_movements, fn {kind, amount_cents} ->
          insert_finance_posting(start, operation, posting_on, nil, kind, amount_cents)
        end)

        :ok
    end
  end

  defp insert_finance_posting(_start, _operation, _posting_on, _property_id, _kind, 0), do: :ok

  defp insert_finance_posting(start, operation, posting_on, property_id, kind, amount_cents) do
    Repo.insert!(%FinancePosting{
      reporting_start_id: start.id,
      operation_id: operation["operation_id"],
      posting_on: posting_on,
      property_id: property_id,
      kind: kind,
      amount_cents: amount_cents
    })

    :ok
  end

  defp reporting_posting_date(operation, starts_on) do
    occurred_on =
      case Map.get(operation, "occurred_on") do
        value when is_binary(value) ->
          case Date.from_iso8601(value) do
            {:ok, date} -> date
            _ -> starts_on
          end

        _ ->
          starts_on
      end

    if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
  end

  defp record_settlement_finance(operation, property_id, settlement) do
    record_finance_movements(
      operation,
      [
        {property_id, "refunded", settlement.refunded_cents},
        {property_id, "retained", settlement.retained_cents},
        {property_id, "converted_to_credit",
         settlement.cash_cents - settlement.refunded_cents - settlement.retained_cents}
      ],
      [
        {"issued", settlement.credit_issued_cents},
        {"consumed", settlement.credit_consumed_cents},
        {"absorbed", settlement.absorbed_cents},
        {"expired", settlement.expired_cents}
      ]
    )
  end

  defp record_chargeback_finance(operation, held_by_group, dispositions, revoked_cents) do
    held_movements =
      Enum.map(held_by_group, fn {group_id, amount_cents} ->
        {Repo.get!(Group, group_id).property_id, "charged_back", amount_cents}
      end)

    settlement_movements =
      Enum.flat_map(dispositions, fn disposition ->
        [
          {disposition.property_id, disposition.kind, -disposition.amount_cents},
          {disposition.property_id, "charged_back", disposition.amount_cents}
        ]
      end)

    record_finance_movements(operation, held_movements ++ settlement_movements, [
      {"revoked", revoked_cents}
    ])
  end

  defp daily_cash_report(start, date) do
    openings =
      FinanceCashOpening
      |> where([opening], opening.reporting_start_id == ^start.id)
      |> select([opening], {opening.property_id, opening.opening_held_cents})
      |> Repo.all()
      |> Map.new()

    prior_movements = cash_postings_before(start, date)
    daily_movements = cash_postings_on(start, date)

    property_ids =
      Map.keys(openings) ++
        Enum.map(prior_movements, &elem(&1, 0)) ++ Enum.map(daily_movements, &elem(&1, 0))

    property_ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      opening_held_cents =
        Map.get(openings, property_id, 0) +
          Enum.sum_by(prior_movements, fn {movement_property_id, kind, amount_cents} ->
            if movement_property_id == property_id, do: cash_delta(kind, amount_cents), else: 0
          end)

      movements =
        daily_movements
        |> Enum.filter(&(elem(&1, 0) == property_id))
        |> Enum.reduce(empty_cash_movements(), fn {_property_id, kind, amount_cents}, movements ->
          Map.update!(movements, String.to_atom(kind <> "_cents"), &(&1 + amount_cents))
        end)

      closing_held_cents = opening_held_cents + cash_movement_delta(movements)

      %{
        property_id: property_id,
        opening_held_cents: opening_held_cents,
        movements: movements,
        closing_held_cents: closing_held_cents
      }
    end)
    |> Enum.reject(fn entry ->
      entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
        Enum.all?(entry.movements, fn {_kind, amount_cents} -> amount_cents == 0 end)
    end)
  end

  defp daily_credit_report(start, date) do
    prior_liability_movements =
      credit_postings_before(start, date)
      |> Enum.sum_by(fn {kind, amount_cents} -> credit_delta(kind, amount_cents) end)

    opening_liability_cents =
      start.opening_credit_liability_cents + prior_liability_movements -
        credit_expiries_before(start, date)

    movements =
      credit_postings_on(start, date)
      |> Enum.reduce(empty_credit_movements(), fn {kind, amount_cents}, movements ->
        Map.update!(movements, String.to_atom(kind <> "_cents"), &(&1 + amount_cents))
      end)
      |> Map.update!(:expired_cents, &(&1 + credit_expiries_on(start, date)))

    %{
      opening_liability_cents: opening_liability_cents,
      movements: movements,
      closing_liability_cents: opening_liability_cents + credit_movement_delta(movements)
    }
  end

  defp cash_postings_before(start, date) do
    FinancePosting
    |> where(
      [posting],
      posting.reporting_start_id == ^start.id and posting.posting_on < ^date and
        not is_nil(posting.property_id)
    )
    |> select([posting], {posting.property_id, posting.kind, posting.amount_cents})
    |> Repo.all()
  end

  defp cash_postings_on(start, date) do
    FinancePosting
    |> where(
      [posting],
      posting.reporting_start_id == ^start.id and posting.posting_on == ^date and
        not is_nil(posting.property_id)
    )
    |> select([posting], {posting.property_id, posting.kind, posting.amount_cents})
    |> Repo.all()
  end

  defp credit_postings_before(start, date) do
    FinancePosting
    |> where(
      [posting],
      posting.reporting_start_id == ^start.id and posting.posting_on < ^date and
        is_nil(posting.property_id)
    )
    |> select([posting], {posting.kind, posting.amount_cents})
    |> Repo.all()
  end

  defp credit_postings_on(start, date) do
    FinancePosting
    |> where(
      [posting],
      posting.reporting_start_id == ^start.id and posting.posting_on == ^date and
        is_nil(posting.property_id)
    )
    |> select([posting], {posting.kind, posting.amount_cents})
    |> Repo.all()
  end

  defp credit_expiries_before(start, date) do
    FinanceCreditExpirySchedule
    |> where(
      [schedule],
      schedule.reporting_start_id == ^start.id and schedule.expires_on < ^date
    )
    |> select([schedule], coalesce(sum(schedule.amount_cents), 0))
    |> Repo.one()
  end

  defp credit_expiries_on(start, date) do
    FinanceCreditExpirySchedule
    |> where(
      [schedule],
      schedule.reporting_start_id == ^start.id and schedule.expires_on == ^date
    )
    |> select([schedule], coalesce(sum(schedule.amount_cents), 0))
    |> Repo.one()
  end

  defp empty_cash_movements do
    %{
      received_cents: 0,
      transferred_in_cents: 0,
      transferred_out_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    }
  end

  defp empty_credit_movements do
    %{issued_cents: 0, expired_cents: 0, consumed_cents: 0, revoked_cents: 0, absorbed_cents: 0}
  end

  defp cash_delta("received", amount_cents), do: amount_cents
  defp cash_delta("transferred_in", amount_cents), do: amount_cents
  defp cash_delta("transferred_out", amount_cents), do: -amount_cents
  defp cash_delta("refunded", amount_cents), do: -amount_cents
  defp cash_delta("retained", amount_cents), do: -amount_cents
  defp cash_delta("converted_to_credit", amount_cents), do: -amount_cents
  defp cash_delta("reduced", amount_cents), do: -amount_cents
  defp cash_delta("charged_back", amount_cents), do: -amount_cents

  defp cash_movement_delta(movements) do
    movements.received_cents + movements.transferred_in_cents - movements.transferred_out_cents -
      movements.refunded_cents - movements.retained_cents - movements.converted_to_credit_cents -
      movements.reduced_cents - movements.charged_back_cents
  end

  defp credit_delta("issued", amount_cents), do: amount_cents
  defp credit_delta("expired", amount_cents), do: -amount_cents
  defp credit_delta("consumed", amount_cents), do: -amount_cents
  defp credit_delta("revoked", amount_cents), do: -amount_cents
  defp credit_delta("absorbed", amount_cents), do: -amount_cents

  defp credit_movement_delta(movements) do
    movements.issued_cents - movements.expired_cents - movements.consumed_cents -
      movements.revoked_cents - movements.absorbed_cents
  end

  defp cash_held_by_property do
    RoomFundingAllocation
    |> join(:inner, [allocation], room in Room,
      on: room.group_id == allocation.group_id and room.room_id == allocation.room_id
    )
    |> join(:inner, [allocation, _room], group in Group,
      on: group.group_id == allocation.group_id
    )
    |> where(
      [allocation, room, _group],
      allocation.funding_kind == "cash" and room.status == "active"
    )
    |> group_by([_allocation, _room, group], group.property_id)
    |> select([allocation, _room, group], {group.property_id, sum(allocation.amount_cents)})
    |> Repo.all()
  end

  defp set_credit_expiry_schedule(lot, start \\ reporting_start())

  defp set_credit_expiry_schedule(_lot, nil), do: :ok

  defp set_credit_expiry_schedule(lot, start) do
    expires_on = later_date(lot.expires_on, start.starts_on)

    case Repo.get_by(FinanceCreditExpirySchedule,
           reporting_start_id: start.id,
           credit_lot_id: lot.id
         ) do
      nil ->
        Repo.insert!(%FinanceCreditExpirySchedule{
          reporting_start_id: start.id,
          credit_lot_id: lot.id,
          expires_on: expires_on,
          amount_cents: lot.remaining_cents
        })

      schedule ->
        Repo.update_all(
          from(current_schedule in FinanceCreditExpirySchedule,
            where: current_schedule.id == ^schedule.id
          ),
          set: [expires_on: expires_on, amount_cents: lot.remaining_cents]
        )
    end

    :ok
  end

  defp reportable_credit_revocation?(lot_id, operation) do
    case reporting_start() do
      nil ->
        false

      start ->
        case Repo.get_by(FinanceCreditExpirySchedule,
               reporting_start_id: start.id,
               credit_lot_id: lot_id
             ) do
          nil ->
            false

          schedule ->
            Date.compare(
              schedule.expires_on,
              reporting_posting_date(operation, start.starts_on)
            ) == :gt
        end
    end
  end

  defp credit_evaluation_date(operation) do
    case reporting_start() do
      nil -> Date.utc_today()
      start -> reporting_posting_date(operation, start.starts_on)
    end
  end

  defp later_date(first, second) do
    if Date.compare(first, second) == :lt, do: second, else: first
  end

  defp cash_held do
    RoomFundingAllocation
    |> join(:inner, [allocation], room in Room,
      on: room.group_id == allocation.group_id and room.room_id == allocation.room_id
    )
    |> where([allocation, room], allocation.funding_kind == "cash" and room.status == "active")
    |> select([allocation], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp group_total(field) do
    Group
    |> select([group], coalesce(sum(field(group, ^field)), 0))
    |> Repo.one()
  end

  defp payment_total(field) do
    CashPayment
    |> select([payment], coalesce(sum(field(payment, ^field)), 0))
    |> Repo.one()
  end

  defp available_lots(guest_id, on) do
    CreditLot
    |> where(
      [lot],
      lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on
    )
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id)
    |> Repo.all()
  end

  defp credit_liability(on) do
    available_cents =
      CreditLot
      |> where([lot], lot.remaining_cents > 0 and lot.expires_on > ^on)
      |> select([lot], coalesce(sum(lot.remaining_cents), 0))
      |> Repo.one()

    available_cents + applied_credit()
  end

  defp credit_shortfall do
    applied_by_lot =
      RoomFundingAllocation
      |> join(:inner, [allocation], room in Room,
        on: room.group_id == allocation.group_id and room.room_id == allocation.room_id
      )
      |> where(
        [allocation, room],
        allocation.funding_kind == "credit" and room.status == "active"
      )
      |> group_by([allocation], allocation.credit_lot_id)
      |> select([allocation], {allocation.credit_lot_id, sum(allocation.amount_cents)})
      |> Repo.all()
      |> Map.new()

    CreditLot
    |> where([lot], lot.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.sum_by(fn lot ->
      min(lot.unrecovered_clawback_cents, Map.get(applied_by_lot, lot.id, 0))
    end)
  end

  defp applied_credit do
    RoomFundingAllocation
    |> join(:inner, [allocation], room in Room,
      on: room.group_id == allocation.group_id and room.room_id == allocation.room_id
    )
    |> where([allocation, room], allocation.funding_kind == "credit" and room.status == "active")
    |> select([allocation], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp reject(operation, code, details \\ %{}) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id"), else: nil

    %{status: "rejected", code: code}
    |> maybe_put(:operation_id, operation_id)
    |> maybe_put(:group_id, if(is_map(operation), do: Map.get(operation, "group_id"), else: nil))
    |> Map.merge(details)
  end

  defp reject_for_group(operation, code, nil, details), do: reject(operation, code, details)

  defp reject_for_group(operation, code, group_id, details),
    do: reject(operation, code, Map.put(details, :group_id, group_id))

  defp maybe_put(result, _key, nil), do: result
  defp maybe_put(result, key, value), do: Map.put(result, key, value)
end
