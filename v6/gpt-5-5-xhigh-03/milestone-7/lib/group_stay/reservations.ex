defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashFunding,
    CreditLot,
    CreditLotCashEntitlement,
    FinanceClosedDailyReport,
    FinanceCashMovement,
    FinanceCashOpeningBalance,
    FinanceCreditMovement,
    FinancePeriodClose,
    FinanceReportingStart,
    Group,
    PartnerOperation,
    Room,
    RoomFundingAllocation
  }

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @policy_flex_14 "flex-14"
  @policy_flex_30 "flex-30"
  @policy_advance_nonrefundable "advance-nonrefundable"
  @flex_30_starts_on ~D[2027-01-01]
  @refund_cash "cash"
  @refund_hotel_credit "hotel_credit"
  @funding_cash "cash"
  @funding_credit "credit"
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

  def process_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def process_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> preload_rooms()
  end

  def group_data(%Group{} = group) do
    group = preload_rooms(group)
    policy_version = policy_version(group)
    room_totals = room_totals_by_room_id(group)
    room_data = Enum.map(group.rooms, &room_data(&1, room_totals))
    active_room_data = Enum.filter(room_data, &(&1.status == @active))
    cash_paid_cents = sum_key(active_room_data, :cash_paid_cents)
    credit_paid_cents = sum_key(active_room_data, :credit_paid_cents)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      policy_version: policy_version,
      refundable_until: refundable_until_iso(group, policy_version),
      rooms:
        Enum.map(room_data, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            status: room.status,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: sum_key(active_room_data, :lodging_total_cents),
      deposit_due_cents: sum_key(active_room_data, :deposit_due_cents),
      deposit_paid_cents: cash_paid_cents + credit_paid_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      outstanding_deposit_cents: active_outstanding_deposit(group)
    }
  end

  def ledger_totals(raw_on \\ nil) do
    on_date = reporting_date(raw_on)

    %{
      cash_held_cents: sum_cash_funding_field(:held_cents),
      cash_refunded_cents: sum_cash_funding_field(:refunded_cents),
      cash_retained_cents: sum_cash_funding_field(:retained_cents),
      cash_converted_to_credit_cents: sum_cash_funding_field(:converted_to_credit_cents),
      cash_reduced_cents: sum_cash_funding_field(:reduced_cents),
      cash_charged_back_cents: sum_cash_funding_field(:charged_back_cents),
      credit_liability_cents: available_credit_total(on_date) + active_credit_allocation_total(),
      credit_shortfall_cents: credit_shortfall_total()
    }
  end

  def daily_finance_report(raw_date) do
    with {:ok, date} <- required_report_date(raw_date),
         {:ok, reporting_start} <- available_finance_report_start(date) do
      {:ok, closed_or_live_daily_report(reporting_start, date)}
    end
  end

  def guest_credit_data(guest_id, raw_on \\ nil) do
    on_date = reporting_date(raw_on)
    lots = available_credit_lots(guest_id, on_date)

    %{
      guest_id: guest_id,
      available_cents: sum_key(lots, :remaining_cents),
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

  def get_operation_result(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      partner_operation -> decode_operation_result(partner_operation)
    end
  end

  def get_payment_reconciliation(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        nil

      partner_operation ->
        with true <- partner_operation.operation_type == "record_cash_payment",
             %{"status" => "applied"} <- decode_operation_result(partner_operation),
             %CashFunding{} = cash_funding <-
               Repo.get_by(CashFunding, payment_operation_id: payment_operation_id) do
          data = %{
            payment_operation_id: payment_operation_id,
            original_group_id: cash_funding_group_id(cash_funding),
            recorded_cents: cash_funding.recorded_cents,
            held_cents: cash_funding.held_cents,
            refunded_cents: cash_funding.refunded_cents,
            retained_cents: cash_funding.retained_cents,
            converted_to_credit_cents: cash_funding.converted_to_credit_cents,
            reduced_cents: cash_funding.reduced_cents,
            charged_back_cents: cash_funding.charged_back_cents
          }

          if cash_funding.transfer_participated do
            Map.put(data, :held_by_group, held_cash_by_group(cash_funding))
          else
            data
          end
        else
          _ -> {:error, :payment_not_reconcilable}
        end
    end
  end

  defp process_operation(operation) do
    case rememberable_operation_id(operation) do
      {:ok, operation_id} -> process_remembered_operation(operation_id, operation)
      :error -> process_unremembered_operation(operation)
    end
  end

  defp process_remembered_operation(operation_id, operation) do
    submitted_json = canonical_json!(operation)
    operation_type = operation_type(operation)

    {:ok, result} =
      Repo.transaction(fn ->
        case reserve_partner_operation(operation_id, operation_type, submitted_json) do
          {:new, partner_operation} ->
            {_status, result} = apply_operation(operation)

            partner_operation
            |> Ecto.Changeset.change(result_json: Jason.encode!(result))
            |> Repo.update!()

            result

          {:existing, partner_operation} ->
            if partner_operation.submitted_json == submitted_json do
              decode_operation_result(partner_operation)
            else
              operation_id_conflict(operation_id)
            end
        end
      end)

    result
  end

  defp process_unremembered_operation(operation) do
    {:ok, {_status, result}} = Repo.transaction(fn -> apply_operation(operation) end)
    result
  end

  defp reserve_partner_operation(operation_id, operation_type, submitted_json) do
    now = DateTime.utc_now(:second)

    {inserted_count, _rows} =
      Repo.insert_all(
        PartnerOperation,
        [
          %{
            operation_id: operation_id,
            operation_type: operation_type,
            submitted_json: submitted_json,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:operation_id]
      )

    partner_operation = Repo.get_by!(PartnerOperation, operation_id: operation_id)

    case inserted_count do
      1 -> {:new, partner_operation}
      0 -> {:existing, partner_operation}
    end
  end

  defp apply_operation(%{"type" => "start_finance_reporting"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, starts_on} <- required_finance_reporting_date(operation, "starts_on"),
         :ok <- finance_reporting_not_started() do
      start_finance_reporting!(operation, starts_on)

      applied(operation, %{
        starts_on: Date.to_iso8601(starts_on)
      })
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "close_finance_period"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, period_end_on} <- required_finance_period_date(operation, "period_end_on"),
         {:ok, reporting_start} <- closable_finance_period(period_end_on) do
      close_finance_period!(operation, reporting_start, period_end_on)

      applied(operation, %{
        period_end_on: Date.to_iso8601(period_end_on)
      })
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, group} <- addressed_active_group(operation),
         {:ok, amount_cents} <- usable_payment_amount(operation),
         :ok <- payment_within_outstanding(group, amount_cents),
         {:ok, posting_date} <- finance_posting_date(operation) do
      cash_funding =
        Repo.insert!(%CashFunding{
          group_id: group.id,
          payment_operation_id: Map.fetch!(operation, "operation_id"),
          recorded_cents: amount_cents,
          held_cents: amount_cents,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 0,
          charged_back_cents: 0
        })

      record_cash_movement(
        posting_date,
        group.property_id,
        "received",
        amount_cents,
        operation,
        cash_funding.id
      )

      allocate_cash_to_rooms(
        group,
        cash_funding,
        amount_cents,
        Map.fetch!(operation, "operation_id")
      )

      group =
        group
        |> Ecto.Changeset.change(
          deposit_paid_cents: active_cash_paid_cents(group),
          revision: group.revision + 1
        )
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: active_outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, group} <- addressed_active_group(operation),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_payment_amount(operation),
         :ok <- payment_within_outstanding(group, amount_cents),
         {:ok, lots} <- credit_lots_covering(group.guest_id, amount_cents, occurred_on),
         posting_date = finance_posting_date(occurred_on) do
      apply_credit_lots(
        group,
        lots,
        amount_cents,
        operation,
        posting_date
      )

      group =
        group
        |> Ecto.Changeset.change(
          credit_paid_cents: active_credit_paid_cents(group),
          revision: group.revision + 1
        )
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: active_outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "transfer_deposit"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, source_group} <- transfer_group(operation, "source_group_id"),
         {:ok, destination_group} <- transfer_group(operation, "destination_group_id"),
         :ok <- group_revision_matches(source_group, operation),
         :ok <-
           group_revision_matches(
             destination_group,
             operation,
             "destination_expected_revision"
           ),
         :ok <- valid_transfer_groups(source_group, destination_group),
         :ok <- transfer_group_active(source_group),
         :ok <- transfer_group_active(destination_group),
         {:ok, amount_cents} <- usable_payment_amount(operation),
         source_allocations = held_allocations_for_group(source_group),
         held_funding_cents = sum_struct_field(source_allocations, :amount_cents),
         :ok <- transfer_within_held_funding(held_funding_cents, amount_cents),
         :ok <- transfer_within_outstanding(destination_group, amount_cents),
         {:ok, posting_date} <- finance_posting_date(operation) do
      drawn_allocations = draw_transfer_allocations(source_allocations, amount_cents)
      cash_transferred_cents = cash_drawn_amount(drawn_allocations)

      record_cash_movement(
        posting_date,
        source_group.property_id,
        "transferred_out",
        cash_transferred_cents,
        operation
      )

      record_cash_movement(
        posting_date,
        destination_group.property_id,
        "transferred_in",
        cash_transferred_cents,
        operation
      )

      allocate_drawn_funding_to_destination(destination_group, drawn_allocations)
      mark_transferred_cash_fundings(drawn_allocations)

      updated_groups =
        refresh_groups_after_funding_change([source_group.id, destination_group.id])

      source_group = Map.fetch!(updated_groups, source_group.id)
      destination_group = Map.fetch!(updated_groups, destination_group.id)

      applied(operation, %{
        source_group_id: source_group.group_id,
        destination_group_id: destination_group.group_id,
        amount_cents: amount_cents,
        source_outstanding_deposit_cents: active_outstanding_deposit(source_group),
        destination_outstanding_deposit_cents: active_outstanding_deposit(destination_group),
        source_revision: source_group.revision,
        destination_revision: destination_group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "reschedule_group"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, group} <- addressed_active_group(operation),
         {:ok, occurred_on} <- reschedule_date(operation, "occurred_on"),
         {:ok, new_arrival_on} <- reschedule_date(operation, "new_arrival_on"),
         :ok <- arrival_after_operation(new_arrival_on, occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      group =
        group
        |> Ecto.Changeset.change(
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        )
        |> Repo.update!()

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(group.arrival_on),
        new_departure_on: Date.to_iso8601(group.departure_on),
        policy_version: policy_version(group),
        refundable_until: refundable_until_iso(group),
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "cancel_group"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, group} <- addressed_active_group(operation),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation),
         active_rooms = active_rooms(group),
         posting_date = finance_posting_date(occurred_on),
         {:ok, settlement} <-
           settle_rooms(group, active_rooms, occurred_on, refund_method, operation, posting_date) do
      group = update_group_after_room_settlement(group)

      applied(operation, %{
        group_id: group.group_id,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "cancel_rooms"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, group} <- addressed_active_group(operation),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation),
         {:ok, rooms} <- selected_active_rooms(group, operation),
         posting_date = finance_posting_date(occurred_on),
         {:ok, settlement} <-
           settle_rooms(group, rooms, occurred_on, refund_method, operation, posting_date) do
      group = update_group_after_room_settlement(group)

      applied(operation, %{
        group_id: group.group_id,
        cancelled_room_ids: Enum.map(rooms, & &1.room_id),
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "reduce_cash_payment"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id"),
         {:ok, cash_funding} <-
           applied_cash_payment_funding(payment_operation_id, "payment_not_reducible"),
         {:ok, group} <- group_for_cash_funding(cash_funding),
         :ok <- group_revision_matches(group, operation),
         {:ok, amount_cents} <- usable_payment_amount(operation),
         held_cents = held_cash_for_funding(cash_funding),
         :ok <- reducible_held_amount(held_cents, amount_cents),
         {:ok, posting_date} <- finance_posting_date(operation) do
      cash_reductions = reduce_held_cash_allocations(cash_funding, amount_cents)
      affected_group_ids = Enum.map(cash_reductions, & &1.group_id)

      record_cash_movements_by_group(
        posting_date,
        "reduced",
        cash_reductions,
        operation,
        cash_funding.id
      )

      cash_funding
      |> Ecto.Changeset.change(
        held_cents: held_cents - amount_cents,
        reduced_cents: cash_funding.reduced_cents + amount_cents
      )
      |> Repo.update!()

      group =
        [group.id | affected_group_ids]
        |> refresh_groups_after_funding_change()
        |> Map.fetch!(group.id)

      applied(operation, %{
        payment_operation_id: payment_operation_id,
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: active_outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(%{"type" => "charge_back_payment"} = operation) do
    with :ok <- operation_identified(operation),
         {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id"),
         {:ok, cash_funding} <-
           applied_cash_payment_funding(payment_operation_id, "payment_not_chargeable"),
         {:ok, group} <- group_for_cash_funding(cash_funding),
         :ok <- group_revision_matches(group, operation),
         :ok <- chargeable_cash_funding(cash_funding),
         {:ok, posting_date} <- finance_posting_date(operation) do
      held_cents = held_cash_for_funding(cash_funding)
      charged_back_cents = cash_funding.recorded_cents - cash_funding.reduced_cents

      cash_reductions = reduce_held_cash_allocations(cash_funding, held_cents)
      affected_group_ids = Enum.map(cash_reductions, & &1.group_id)

      record_chargeback_cash_movements(
        posting_date,
        operation,
        cash_funding,
        cash_reductions
      )

      revoke_credit_entitlements(cash_funding, posting_date, operation)

      cash_funding
      |> Ecto.Changeset.change(
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: cash_funding.charged_back_cents + charged_back_cents
      )
      |> Repo.update!()

      group =
        [group.id | affected_group_ids]
        |> refresh_groups_after_funding_change()
        |> Map.fetch!(group.id)

      applied(operation, %{
        payment_operation_id: payment_operation_id,
        group_id: group.group_id,
        charged_back_cents: charged_back_cents,
        outstanding_deposit_cents: active_outstanding_deposit(group),
        revision: group.revision
      })
    else
      {:error, code, attrs} -> rejected(operation, code, attrs)
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_operation(operation), do: rejected(operation, "invalid_operation")

  defp open_group(operation) do
    with :ok <- operation_identified(operation),
         {:ok, attrs} <- open_group_attrs(operation),
         :ok <- group_id_available(attrs.group_id),
         {:ok, arrival_on, departure_on, nights} <-
           valid_stay(attrs.arrival_on, attrs.departure_on),
         {:ok, rooms} <- valid_rooms(attrs.rooms),
         {:ok, rate_plan} <- valid_rate_plan(attrs.rate_plan) do
      room_totals = room_totals(rooms, nights, rate_plan)

      group =
        %Group{
          group_id: attrs.group_id,
          guest_id: attrs.guest_id,
          property_id: attrs.property_id,
          booked_on: attrs.booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          status: @active,
          policy_version: policy_version_for(rate_plan, attrs.booked_on),
          lodging_total_cents: sum_key(room_totals, :lodging_total_cents),
          deposit_due_cents: sum_key(room_totals, :deposit_due_cents),
          deposit_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          revision: 1
        }
        |> Repo.insert!()

      room_totals
      |> Enum.with_index()
      |> Enum.each(fn {room, index} ->
        Repo.insert!(%Room{
          group_id: group.id,
          position: index,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          lodging_total_cents: room.lodging_total_cents,
          deposit_due_cents: room.deposit_due_cents,
          status: @active
        })
      end)

      applied(operation, %{
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      })
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp open_group_attrs(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, booked_on} <- required_date(operation, "occurred_on"),
         {:ok, arrival_on} <- required_raw(operation, "arrival_on"),
         {:ok, departure_on} <- required_raw(operation, "departure_on"),
         {:ok, rate_plan} <- required_raw(operation, "rate_plan"),
         {:ok, rooms} <- required_raw(operation, "rooms") do
      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       }}
    else
      {:error, _code} -> {:error, "invalid_operation"}
    end
  end

  defp operation_identified(operation) do
    with {:ok, _operation_id} <- required_string(operation, "operation_id") do
      :ok
    end
  end

  defp addressed_active_group(operation) do
    with {:ok, group} <- addressed_group(operation) do
      if group.status == @active do
        {:ok, group}
      else
        {:error, "group_not_active"}
      end
    end
  end

  defp addressed_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          {:error, "group_not_found", %{group_id: group_id}}

        group ->
          expected_revision = Map.get(operation, "expected_revision")

          if is_nil(expected_revision) or expected_revision == group.revision do
            {:ok, group}
          else
            {:error, "stale_revision",
             %{
               group_id: group.group_id,
               expected_revision: expected_revision,
               actual_revision: group.revision
             }}
          end
      end
    else
      {:error, _code} -> {:error, "invalid_operation"}
    end
  end

  defp transfer_group(operation, key) do
    with {:ok, group_id} <- required_string(operation, key) do
      case Repo.get_by(Group, group_id: group_id) do
        nil -> {:error, "group_not_found", %{group_id: group_id}}
        group -> {:ok, group}
      end
    else
      {:error, _code} -> {:error, "invalid_operation"}
    end
  end

  defp valid_transfer_groups(source_group, destination_group) do
    cond do
      source_group.id == destination_group.id -> {:error, "invalid_transfer"}
      source_group.guest_id != destination_group.guest_id -> {:error, "invalid_transfer"}
      true -> :ok
    end
  end

  defp transfer_group_active(%Group{status: @active}), do: :ok

  defp transfer_group_active(%Group{} = group) do
    {:error, "group_not_active", %{group_id: group.group_id}}
  end

  defp group_id_available(group_id) do
    if Repo.exists?(from group in Group, where: group.group_id == ^group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp valid_stay(arrival_on, departure_on) do
    with {:ok, arrival_on} <- parse_date(arrival_on),
         {:ok, departure_on} <- parse_date(departure_on),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {room, _index}, {:ok, acc, seen_ids} ->
      with {:ok, room_id} <- required_string(room, "room_id"),
           false <- MapSet.member?(seen_ids, room_id),
           {:ok, nightly_rate_cents} <- non_negative_integer(room, "nightly_rate_cents") do
        parsed_room = %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}
        {:cont, {:ok, [parsed_room | acc], MapSet.put(seen_ids, room_id)}}
      else
        _ -> {:halt, {:error, "invalid_rooms"}}
      end
    end)
    |> case do
      {:ok, rooms, _seen_ids} -> {:ok, Enum.reverse(rooms)}
      {:error, code} -> {:error, code}
    end
  end

  defp valid_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp valid_rate_plan(rate_plan) when rate_plan in [@flexible, @advance_purchase],
    do: {:ok, rate_plan}

  defp valid_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp room_totals(rooms, nights, rate_plan) do
    Enum.map(rooms, fn room ->
      lodging_total_cents = room.nightly_rate_cents * nights

      deposit_due_cents =
        case rate_plan do
          @flexible -> round_percentage(lodging_total_cents, 20)
          @advance_purchase -> lodging_total_cents
        end

      Map.merge(room, %{
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents
      })
    end)
  end

  defp round_percentage(amount_cents, percentage) do
    div(amount_cents * percentage + 50, 100)
  end

  defp usable_payment_amount(operation),
    do: payment_amount(operation, "amount_cents")

  defp payment_amount(operation, key) do
    case required_raw(operation, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_amount"}
      {:error, _code} -> {:error, "invalid_operation"}
    end
  end

  defp payment_within_outstanding(group, amount_cents) do
    if amount_cents <= active_outstanding_deposit(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp transfer_within_held_funding(held_funding_cents, amount_cents) do
    if amount_cents <= held_funding_cents do
      :ok
    else
      {:error, "transfer_exceeds_held_funding"}
    end
  end

  defp transfer_within_outstanding(group, amount_cents) do
    if amount_cents <= active_outstanding_deposit(group) do
      :ok
    else
      {:error, "transfer_exceeds_outstanding"}
    end
  end

  defp arrival_after_operation(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp credit_lots_covering(guest_id, amount_cents, occurred_on) do
    lots = available_credit_lots(guest_id, occurred_on)

    if sum_key(lots, :remaining_cents) >= amount_cents do
      {:ok, lots}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp apply_credit_lots(group, lots, amount_cents, operation, posting_date) do
    source_operation_id = Map.fetch!(operation, "operation_id")

    Enum.reduce_while(lots, amount_cents, fn lot, remaining_cents ->
      if remaining_cents == 0 do
        {:halt, 0}
      else
        applied_cents = min(lot.remaining_cents, remaining_cents)

        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - applied_cents)
        |> Repo.update!()

        record_credit_application_expiry_adjustment(lot, applied_cents, posting_date, operation)
        allocate_credit_to_rooms(group, lot, applied_cents, source_operation_id)

        {:cont, remaining_cents - applied_cents}
      end
    end)

    :ok
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", @refund_cash) do
      method when method in [@refund_cash, @refund_hotel_credit] -> {:ok, method}
      _other -> {:error, "invalid_operation"}
    end
  end

  defp selected_active_rooms(group, operation) do
    with {:ok, room_ids} <- required_raw(operation, "room_ids"),
         true <- is_list(room_ids) and room_ids != [],
         true <- Enum.all?(room_ids, &is_binary/1),
         true <- Enum.uniq(room_ids) == room_ids do
      requested_room_ids = MapSet.new(room_ids)
      active_rooms = active_rooms(group)
      active_room_ids = MapSet.new(active_rooms, & &1.room_id)

      if MapSet.subset?(requested_room_ids, active_room_ids) do
        {:ok, Enum.filter(active_rooms, &MapSet.member?(requested_room_ids, &1.room_id))}
      else
        {:error, "invalid_rooms"}
      end
    else
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp settle_rooms(group, rooms, occurred_on, refund_method, operation, posting_date) do
    refundable? = refundable_cancellation?(group, occurred_on)

    if refund_method == @refund_hotel_credit and not refundable? do
      {:error, "refund_method_not_available"}
    else
      cash_allocations = cash_allocations_for_rooms(rooms)
      credit_allocations = credit_allocations_for_rooms(rooms)
      cash_paid_cents = sum_struct_field(cash_allocations, :amount_cents)

      {:ok, settlement} =
        cash_cancellation_settlement(cash_paid_cents, refundable?, refund_method)

      settle_cash_allocations(
        cash_allocations,
        settlement,
        posting_date,
        group.property_id,
        operation
      )

      settle_credit_allocations(
        credit_allocations,
        occurred_on,
        settlement.refundable?,
        posting_date,
        operation
      )

      create_credit_lot(
        group,
        operation,
        occurred_on,
        settlement.credit_issued_cents,
        cash_allocations,
        posting_date
      )

      cancel_rooms!(rooms)
      delete_allocations(cash_allocations ++ credit_allocations)

      {:ok, settlement}
    end
  end

  defp cash_cancellation_settlement(cash_paid_cents, true, @refund_cash) do
    {:ok,
     %{
       refundable?: true,
       cash_disposition: :refunded_cents,
       refunded_cents: cash_paid_cents,
       retained_cents: 0,
       cash_converted_to_credit_cents: 0,
       credit_issued_cents: 0
     }}
  end

  defp cash_cancellation_settlement(cash_paid_cents, true, @refund_hotel_credit) do
    credit_issued_cents = bonus_value(cash_paid_cents)

    {:ok,
     %{
       refundable?: true,
       cash_disposition: :converted_to_credit_cents,
       refunded_cents: 0,
       retained_cents: 0,
       cash_converted_to_credit_cents: cash_paid_cents,
       credit_issued_cents: credit_issued_cents
     }}
  end

  defp cash_cancellation_settlement(cash_paid_cents, false, @refund_cash) do
    {:ok,
     %{
       refundable?: false,
       cash_disposition: :retained_cents,
       refunded_cents: 0,
       retained_cents: cash_paid_cents,
       cash_converted_to_credit_cents: 0,
       credit_issued_cents: 0
     }}
  end

  defp cash_settlement_movement_type(:refunded_cents), do: "refunded"
  defp cash_settlement_movement_type(:retained_cents), do: "retained"
  defp cash_settlement_movement_type(:converted_to_credit_cents), do: "converted_to_credit"

  defp settle_cash_allocations(allocations, settlement, posting_date, property_id, operation) do
    allocations
    |> Enum.group_by(& &1.cash_funding_id)
    |> Enum.each(fn {cash_funding_id, funding_allocations} ->
      amount_cents = sum_struct_field(funding_allocations, :amount_cents)
      cash_funding = Repo.get!(CashFunding, cash_funding_id)

      current_disposition_cents =
        Map.fetch!(Map.from_struct(cash_funding), settlement.cash_disposition)

      cash_funding
      |> Ecto.Changeset.change(
        Map.merge(
          %{held_cents: cash_funding.held_cents - amount_cents},
          %{settlement.cash_disposition => current_disposition_cents + amount_cents}
        )
      )
      |> Repo.update!()

      record_cash_movement(
        posting_date,
        property_id,
        cash_settlement_movement_type(settlement.cash_disposition),
        amount_cents,
        operation,
        cash_funding_id
      )
    end)
  end

  defp settle_credit_allocations(allocations, occurred_on, true, posting_date, operation) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {credit_lot_id, lot_allocations} ->
      restore_credit_to_lot(
        credit_lot_id,
        sum_struct_field(lot_allocations, :amount_cents),
        occurred_on,
        posting_date,
        operation
      )
    end)
  end

  defp settle_credit_allocations(allocations, _occurred_on, false, posting_date, operation) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {credit_lot_id, lot_allocations} ->
      record_credit_movement(
        posting_date,
        "consumed",
        sum_struct_field(lot_allocations, :amount_cents),
        operation,
        credit_lot_id
      )
    end)
  end

  defp restore_credit_to_lot(credit_lot_id, amount_cents, occurred_on, posting_date, operation) do
    lot = Repo.get!(CreditLot, credit_lot_id)
    absorbed_cents = min(lot.unrecovered_clawback_cents || 0, amount_cents)
    restorable_cents = amount_cents - absorbed_cents
    unexpired_on_occurrence? = Date.compare(lot.expires_on, occurred_on) == :gt

    persisted_posting_date = posting_date_value(posting_date)

    unexpired_on_posting? =
      is_nil(persisted_posting_date) or
        Date.compare(lot.expires_on, persisted_posting_date) == :gt

    restored_available_cents = if unexpired_on_occurrence?, do: restorable_cents, else: 0

    expired_cents =
      restorable_cents - if(unexpired_on_posting?, do: restored_available_cents, else: 0)

    remaining_cents =
      if unexpired_on_occurrence? do
        lot.remaining_cents + restored_available_cents
      else
        lot.remaining_cents
      end

    lot
    |> Ecto.Changeset.change(
      remaining_cents: remaining_cents,
      unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) - absorbed_cents
    )
    |> Repo.update!()

    record_credit_movement(posting_date, "absorbed", absorbed_cents, operation, lot.id)
    record_credit_movement(posting_date, "expired", expired_cents, operation, lot.id)

    if unexpired_on_posting? do
      record_credit_expiry_adjustment(lot, restored_available_cents, posting_date)
    end
  end

  defp create_credit_lot(_group, _operation, _occurred_on, 0, _cash_allocations, _posting_date),
    do: :ok

  defp create_credit_lot(
         group,
         operation,
         occurred_on,
         credit_issued_cents,
         cash_allocations,
         posting_date
       ) do
    credit_lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: Map.fetch!(operation, "operation_id"),
        remaining_cents: credit_issued_cents,
        unrecovered_clawback_cents: 0,
        expires_on: Date.add(occurred_on, 366)
      })

    record_credit_movement(posting_date, "issued", credit_issued_cents, operation, credit_lot.id)

    persisted_posting_date = posting_date_value(posting_date)

    if is_nil(persisted_posting_date) or
         Date.compare(credit_lot.expires_on, persisted_posting_date) == :gt do
      record_credit_expiry_adjustment(credit_lot, credit_issued_cents, posting_date)
    else
      record_credit_movement(
        posting_date,
        "expired",
        credit_issued_cents,
        operation,
        credit_lot.id
      )
    end

    insert_credit_entitlements(credit_lot, cash_allocations)

    :ok
  end

  defp insert_credit_entitlements(credit_lot, cash_allocations) do
    cash_allocations
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&%{cash_funding_id: &1.cash_funding_id, principal_cents: &1.amount_cents})
    |> entitlement_rows()
    |> Enum.each(fn {_cash_funding_id, row} ->
      Repo.insert!(%CreditLotCashEntitlement{
        credit_lot_id: credit_lot.id,
        cash_funding_id: row.cash_funding_id,
        principal_cents: row.principal_cents,
        entitlement_cents: row.entitlement_cents
      })
    end)
  end

  defp entitlement_rows(sources) do
    {_running_principal, rows_by_funding} =
      Enum.reduce(sources, {0, %{}}, fn source, {running_principal, rows_by_funding} ->
        next_running_principal = running_principal + source.principal_cents
        entitlement_cents = bonus_value(next_running_principal) - bonus_value(running_principal)

        rows_by_funding =
          Map.update(
            rows_by_funding,
            source.cash_funding_id,
            %{
              cash_funding_id: source.cash_funding_id,
              principal_cents: source.principal_cents,
              entitlement_cents: entitlement_cents
            },
            fn row ->
              %{
                row
                | principal_cents: row.principal_cents + source.principal_cents,
                  entitlement_cents: row.entitlement_cents + entitlement_cents
              }
            end
          )

        {next_running_principal, rows_by_funding}
      end)

    rows_by_funding
  end

  defp bonus_value(principal_cents), do: principal_cents + round_percentage(principal_cents, 10)

  defp refundable_cancellation?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) in [:lt, :eq]
    end
  end

  defp allocate_cash_to_rooms(group, cash_funding, amount_cents, source_operation_id) do
    allocate_to_rooms(group, amount_cents, fn room, allocated_cents ->
      Repo.insert!(%RoomFundingAllocation{
        group_id: group.id,
        room_id: room.id,
        funding_type: @funding_cash,
        amount_cents: allocated_cents,
        source_operation_id: source_operation_id,
        cash_funding_id: cash_funding.id
      })
    end)
  end

  defp allocate_credit_to_rooms(group, credit_lot, amount_cents, source_operation_id) do
    allocate_to_rooms(group, amount_cents, fn room, allocated_cents ->
      Repo.insert!(%RoomFundingAllocation{
        group_id: group.id,
        room_id: room.id,
        funding_type: @funding_credit,
        amount_cents: allocated_cents,
        source_operation_id: source_operation_id,
        credit_lot_id: credit_lot.id
      })
    end)
  end

  defp allocate_drawn_funding_to_destination(group, drawn_allocations) do
    Enum.each(drawn_allocations, fn drawn_allocation ->
      allocate_to_rooms(group, drawn_allocation.amount_cents, fn room, allocated_cents ->
        Repo.insert!(%RoomFundingAllocation{
          group_id: group.id,
          room_id: room.id,
          funding_type: drawn_allocation.funding_type,
          amount_cents: allocated_cents,
          source_operation_id: drawn_allocation.source_operation_id,
          cash_funding_id: drawn_allocation.cash_funding_id,
          credit_lot_id: drawn_allocation.credit_lot_id
        })
      end)
    end)

    :ok
  end

  defp allocate_to_rooms(group, amount_cents, insert_fun) do
    group
    |> active_rooms()
    |> Enum.reduce_while(amount_cents, fn room, remaining_cents ->
      cond do
        remaining_cents == 0 ->
          {:halt, 0}

        true ->
          allocated_cents = min(room_outstanding_deposit(room), remaining_cents)

          if allocated_cents > 0 do
            insert_fun.(room, allocated_cents)
          end

          {:cont, remaining_cents - allocated_cents}
      end
    end)

    :ok
  end

  defp draw_transfer_allocations(source_allocations, amount_cents) do
    {_remaining_cents, drawn_allocations} =
      Enum.reduce_while(source_allocations, {amount_cents, []}, fn allocation,
                                                                   {remaining_cents,
                                                                    drawn_allocations} ->
        cond do
          remaining_cents == 0 ->
            {:halt, {0, drawn_allocations}}

          allocation.amount_cents <= remaining_cents ->
            Repo.delete!(allocation)

            drawn_allocation = drawn_allocation(allocation, allocation.amount_cents)

            {:cont,
             {remaining_cents - allocation.amount_cents, [drawn_allocation | drawn_allocations]}}

          true ->
            allocation
            |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - remaining_cents)
            |> Repo.update!()

            drawn_allocation = drawn_allocation(allocation, remaining_cents)
            {:halt, {0, [drawn_allocation | drawn_allocations]}}
        end
      end)

    Enum.reverse(drawn_allocations)
  end

  defp drawn_allocation(allocation, amount_cents) do
    %{
      funding_type: allocation.funding_type,
      amount_cents: amount_cents,
      source_operation_id: allocation.source_operation_id,
      cash_funding_id: allocation.cash_funding_id,
      credit_lot_id: allocation.credit_lot_id
    }
  end

  defp cash_drawn_amount(drawn_allocations) do
    drawn_allocations
    |> Enum.filter(&(&1.funding_type == @funding_cash))
    |> sum_key(:amount_cents)
  end

  defp mark_transferred_cash_fundings(drawn_allocations) do
    cash_funding_ids =
      drawn_allocations
      |> Enum.map(& &1.cash_funding_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if cash_funding_ids != [] do
      CashFunding
      |> where([funding], funding.id in ^cash_funding_ids)
      |> Repo.update_all(set: [transfer_participated: true])
    end

    :ok
  end

  defp reduce_held_cash_allocations(_cash_funding, 0), do: []

  defp reduce_held_cash_allocations(cash_funding, amount_cents) do
    {_remaining_cents, cash_reductions} =
      cash_funding
      |> held_cash_allocations()
      |> Enum.reduce_while({amount_cents, []}, fn allocation,
                                                  {remaining_cents, cash_reductions} ->
        cond do
          remaining_cents == 0 ->
            {:halt, {0, cash_reductions}}

          allocation.amount_cents <= remaining_cents ->
            Repo.delete!(allocation)
            cash_reduction = cash_reduction(allocation, allocation.amount_cents)

            {:cont,
             {remaining_cents - allocation.amount_cents, [cash_reduction | cash_reductions]}}

          true ->
            allocation
            |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - remaining_cents)
            |> Repo.update!()

            cash_reduction = cash_reduction(allocation, remaining_cents)
            {:halt, {0, [cash_reduction | cash_reductions]}}
        end
      end)

    Enum.reverse(cash_reductions)
  end

  defp cash_reduction(allocation, amount_cents) do
    %{
      group_id: allocation.group_id,
      amount_cents: amount_cents
    }
  end

  defp revoke_credit_entitlements(cash_funding, posting_date, operation) do
    CreditLotCashEntitlement
    |> where([entitlement], entitlement.cash_funding_id == ^cash_funding.id)
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removable_cents = min(lot.remaining_cents, entitlement.entitlement_cents)
      unrecovered_cents = entitlement.entitlement_cents - removable_cents
      persisted_posting_date = posting_date_value(posting_date)

      revokes_liability? =
        is_nil(persisted_posting_date) or
          Date.compare(lot.expires_on, persisted_posting_date) == :gt

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removable_cents,
        unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + unrecovered_cents
      )
      |> Repo.update!()

      if revokes_liability? do
        record_credit_movement(posting_date, "revoked", removable_cents, operation, lot.id)
        record_credit_expiry_adjustment(lot, -removable_cents, posting_date)
      end
    end)
  end

  defp chargeable_cash_funding(cash_funding) do
    cond do
      cash_funding.charged_back_cents > 0 ->
        {:error, "payment_not_chargeable"}

      cash_funding.reduced_cents >= cash_funding.recorded_cents ->
        {:error, "payment_not_chargeable"}

      true ->
        :ok
    end
  end

  defp applied_cash_payment_funding(payment_operation_id, invalid_code) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, "operation_not_found"}

      partner_operation ->
        result = decode_operation_result(partner_operation)

        if partner_operation.operation_type == "record_cash_payment" and
             result["status"] == "applied" do
          case Repo.get_by(CashFunding, payment_operation_id: payment_operation_id) do
            nil -> {:error, invalid_code}
            cash_funding -> {:ok, cash_funding}
          end
        else
          {:error, invalid_code}
        end
    end
  end

  defp group_for_cash_funding(cash_funding) do
    case Repo.get(Group, cash_funding.group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp group_revision_matches(group, operation, revision_key \\ "expected_revision") do
    expected_revision = Map.get(operation, revision_key)

    if is_nil(expected_revision) or expected_revision == group.revision do
      :ok
    else
      {:error, "stale_revision",
       %{
         group_id: group.group_id,
         expected_revision: expected_revision,
         actual_revision: group.revision
       }}
    end
  end

  defp reducible_held_amount(held_cents, amount_cents) do
    cond do
      held_cents <= 0 -> {:error, "payment_not_reducible"}
      amount_cents > held_cents -> {:error, "reduction_exceeds_held_cash"}
      true -> :ok
    end
  end

  defp active_rooms(group) do
    Room
    |> where([room], room.group_id == ^group.id)
    |> where([room], room.status == ^@active)
    |> order_by([room], asc: room.position)
    |> Repo.all()
  end

  defp held_allocations_for_group(group) do
    RoomFundingAllocation
    |> join(:inner, [allocation], room in Room, on: room.id == allocation.room_id)
    |> where([allocation, _room], allocation.group_id == ^group.id)
    |> where([allocation, _room], allocation.funding_type in ^[@funding_cash, @funding_credit])
    |> where([_allocation, room], room.status == ^@active)
    |> order_by([allocation, _room], desc: allocation.id)
    |> Repo.all()
  end

  defp room_outstanding_deposit(room) do
    max(room.deposit_due_cents - room_paid_cents(room), 0)
  end

  defp room_paid_cents(room), do: room_cash_paid_cents(room) + room_credit_paid_cents(room)

  defp room_cash_paid_cents(room), do: room_allocation_total(room, @funding_cash)

  defp room_credit_paid_cents(room), do: room_allocation_total(room, @funding_credit)

  defp room_allocation_total(room, funding_type) do
    RoomFundingAllocation
    |> where([allocation], allocation.room_id == ^room.id)
    |> where([allocation], allocation.funding_type == ^funding_type)
    |> select([allocation], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp cash_allocations_for_rooms(rooms), do: allocations_for_rooms(rooms, @funding_cash)

  defp credit_allocations_for_rooms(rooms), do: allocations_for_rooms(rooms, @funding_credit)

  defp allocations_for_rooms([], _funding_type), do: []

  defp allocations_for_rooms(rooms, funding_type) do
    room_ids = Enum.map(rooms, & &1.id)

    RoomFundingAllocation
    |> where([allocation], allocation.room_id in ^room_ids)
    |> where([allocation], allocation.funding_type == ^funding_type)
    |> order_by([allocation], asc: allocation.id)
    |> Repo.all()
  end

  defp held_cash_allocations(cash_funding) do
    RoomFundingAllocation
    |> join(:inner, [allocation], room in Room, on: room.id == allocation.room_id)
    |> where([allocation, _room], allocation.cash_funding_id == ^cash_funding.id)
    |> where([allocation, _room], allocation.funding_type == ^@funding_cash)
    |> where([_allocation, room], room.status == ^@active)
    |> order_by([allocation, _room], desc: allocation.id)
    |> Repo.all()
  end

  defp held_cash_for_funding(cash_funding) do
    cash_funding
    |> held_cash_allocations()
    |> sum_struct_field(:amount_cents)
  end

  defp delete_allocations([]), do: :ok

  defp delete_allocations(allocations) do
    allocation_ids = Enum.map(allocations, & &1.id)

    RoomFundingAllocation
    |> where([allocation], allocation.id in ^allocation_ids)
    |> Repo.delete_all()

    :ok
  end

  defp cancel_rooms!([]), do: :ok

  defp cancel_rooms!(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Room
    |> where([room], room.id in ^room_ids)
    |> Repo.update_all(set: [status: @cancelled])

    :ok
  end

  defp update_group_after_room_settlement(group) do
    status =
      case active_rooms(group) do
        [] -> @cancelled
        _rooms -> @active
      end

    group
    |> Ecto.Changeset.change(
      status: status,
      lodging_total_cents: active_room_sum(group, :lodging_total_cents),
      deposit_due_cents: active_room_sum(group, :deposit_due_cents),
      deposit_paid_cents: active_cash_paid_cents(group),
      credit_paid_cents: active_credit_paid_cents(group),
      refunded_cents: cash_funding_sum_for_group(group, :refunded_cents),
      retained_cents: cash_funding_sum_for_group(group, :retained_cents),
      cash_converted_to_credit_cents:
        cash_funding_sum_for_group(group, :converted_to_credit_cents),
      revision: group.revision + 1
    )
    |> Repo.update!()
  end

  defp refresh_groups_after_funding_change(group_ids) do
    group_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn group_id, groups_by_id ->
      group = Repo.get!(Group, group_id)

      group =
        group
        |> Ecto.Changeset.change(
          deposit_paid_cents: active_cash_paid_cents(group),
          credit_paid_cents: active_credit_paid_cents(group),
          refunded_cents: cash_funding_sum_for_group(group, :refunded_cents),
          retained_cents: cash_funding_sum_for_group(group, :retained_cents),
          cash_converted_to_credit_cents:
            cash_funding_sum_for_group(group, :converted_to_credit_cents),
          revision: group.revision + 1
        )
        |> Repo.update!()

      Map.put(groups_by_id, group.id, group)
    end)
  end

  defp active_outstanding_deposit(group) do
    due_cents = active_room_sum(group, :deposit_due_cents)
    max(due_cents - active_cash_paid_cents(group) - active_credit_paid_cents(group), 0)
  end

  defp active_cash_paid_cents(group), do: active_allocation_total(group, @funding_cash)

  defp active_credit_paid_cents(group), do: active_allocation_total(group, @funding_credit)

  defp active_allocation_total(group, funding_type) do
    RoomFundingAllocation
    |> join(:inner, [allocation], room in Room, on: room.id == allocation.room_id)
    |> where([allocation, _room], allocation.group_id == ^group.id)
    |> where([allocation, _room], allocation.funding_type == ^funding_type)
    |> where([_allocation, room], room.status == ^@active)
    |> select([allocation, _room], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp active_room_sum(group, field) do
    Room
    |> where([room], room.group_id == ^group.id)
    |> where([room], room.status == ^@active)
    |> select([room], coalesce(sum(field(room, ^field)), 0))
    |> Repo.one()
  end

  defp cash_funding_sum_for_group(group, field) do
    CashFunding
    |> where([funding], funding.group_id == ^group.id)
    |> select([funding], coalesce(sum(field(funding, ^field)), 0))
    |> Repo.one()
  end

  defp policy_version(%Group{policy_version: policy_version}) when is_binary(policy_version),
    do: policy_version

  defp policy_version(%Group{} = group), do: policy_version_for(group.rate_plan, group.booked_on)

  defp policy_version_for(@advance_purchase, _booked_on), do: @policy_advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @flex_30_starts_on) == :lt do
      @policy_flex_14
    else
      @policy_flex_30
    end
  end

  defp refundable_until_iso(%Group{} = group, policy_version \\ nil) do
    case refundable_until(group, policy_version) do
      nil -> nil
      refundable_until -> Date.to_iso8601(refundable_until)
    end
  end

  defp refundable_until(%Group{} = group, policy_version \\ nil) do
    case policy_version || policy_version(group) do
      @policy_flex_14 -> Date.add(group.arrival_on, -14)
      @policy_flex_30 -> Date.add(group.arrival_on, -30)
      @policy_advance_nonrefundable -> nil
    end
  end

  defp available_credit_lots(guest_id, on_date) do
    CreditLot
    |> where([lot], lot.guest_id == ^guest_id)
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^on_date)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  defp preload_rooms(nil), do: nil

  defp preload_rooms(%Group{} = group) do
    Repo.preload(group, rooms: from(room in Room, order_by: room.position))
  end

  defp room_totals_by_room_id(group) do
    RoomFundingAllocation
    |> where([allocation], allocation.group_id == ^group.id)
    |> group_by([allocation], [allocation.room_id, allocation.funding_type])
    |> select([allocation], {
      allocation.room_id,
      allocation.funding_type,
      coalesce(sum(allocation.amount_cents), 0)
    })
    |> Repo.all()
    |> Enum.reduce(%{}, fn {room_id, funding_type, amount_cents}, acc ->
      Map.update(acc, room_id, %{funding_type => amount_cents}, fn totals ->
        Map.put(totals, funding_type, amount_cents)
      end)
    end)
  end

  defp room_data(room, room_totals) do
    totals = Map.get(room_totals, room.id, %{})

    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_total_cents: room.lodging_total_cents || 0,
      deposit_due_cents: room.deposit_due_cents || 0,
      status: room.status || @active,
      cash_paid_cents: Map.get(totals, @funding_cash, 0),
      credit_paid_cents: Map.get(totals, @funding_credit, 0)
    }
  end

  defp required_raw(params, key) when is_map(params) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp required_raw(_params, _key), do: {:error, "invalid_operation"}

  defp required_string(params, key) do
    with {:ok, value} <- required_raw(params, key),
         true <- is_binary(value),
         trimmed when trimmed != "" <- String.trim(value) do
      {:ok, value}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_date(params, key) do
    with {:ok, raw_date} <- required_raw(params, key),
         {:ok, date} <- parse_date(raw_date) do
      {:ok, date}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(date) when is_binary(date), do: Date.from_iso8601(date)
  defp parse_date(_date), do: {:error, :invalid_date}

  defp reporting_date(nil), do: Date.utc_today()
  defp reporting_date(%Date{} = date), do: date

  defp reporting_date(raw_date) do
    case parse_date(raw_date) do
      {:ok, date} -> date
      {:error, _reason} -> Date.utc_today()
    end
  end

  defp required_report_date(raw_date) when is_binary(raw_date), do: parse_report_date(raw_date)
  defp required_report_date(_raw_date), do: {:error, :invalid_reporting_date}

  defp parse_report_date(raw_date) do
    case parse_date(raw_date) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  defp required_finance_reporting_date(params, key) do
    with {:ok, raw_date} <- required_raw(params, key),
         {:ok, date} <- parse_date(raw_date) do
      {:ok, date}
    else
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  defp required_finance_period_date(params, key) do
    with {:ok, raw_date} <- required_raw(params, key),
         {:ok, date} <- parse_date(raw_date) do
      {:ok, date}
    else
      _ -> {:error, "invalid_period"}
    end
  end

  defp available_finance_report_start(date) do
    case finance_reporting_start() do
      nil ->
        {:error, :report_not_available}

      %FinanceReportingStart{} = reporting_start ->
        if Date.compare(date, reporting_start.starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, reporting_start}
        end
    end
  end

  defp closed_or_live_daily_report(reporting_start, date) do
    case Repo.get_by(FinanceClosedDailyReport, report_date: date) do
      nil -> daily_report_data(reporting_start, date, "open")
      closed_report -> Jason.decode!(closed_report.data_json)
    end
  end

  defp finance_reporting_start do
    FinanceReportingStart
    |> order_by([start], asc: start.id)
    |> limit(1)
    |> Repo.one()
  end

  defp finance_reporting_not_started do
    if Repo.exists?(FinanceReportingStart) do
      {:error, "reporting_already_started"}
    else
      :ok
    end
  end

  defp finance_posting_date(%Date{} = occurred_on) do
    case finance_reporting_start() do
      nil ->
        posting_context(nil, false)

      %FinanceReportingStart{} = reporting_start ->
        finance_posting_context(occurred_on, reporting_start)
    end
  end

  defp finance_posting_date(operation) do
    case finance_reporting_start() do
      nil ->
        {:ok, posting_context(nil, false)}

      %FinanceReportingStart{} = reporting_start ->
        with {:ok, occurred_on} <- required_date(operation, "occurred_on") do
          {:ok, finance_posting_context(occurred_on, reporting_start)}
        else
          {:error, _code} -> {:error, "invalid_operation"}
        end
    end
  end

  defp finance_posting_context(occurred_on, reporting_start) do
    ordinary_posting_date = max_date(occurred_on, reporting_start.starts_on)

    case latest_finance_period_close() do
      nil ->
        posting_context(ordinary_posting_date, false)

      %FinancePeriodClose{} = period_close ->
        first_open_date = Date.add(period_close.period_end_on, 1)
        posting_date = max_date(ordinary_posting_date, first_open_date)

        posting_context(
          posting_date,
          Date.compare(posting_date, ordinary_posting_date) == :gt
        )
    end
  end

  defp posting_context(date, late_adjustment?) do
    %{date: date, late_adjustment?: late_adjustment?}
  end

  defp posting_date_value(%{date: date}), do: date
  defp posting_date_value(%Date{} = date), do: date
  defp posting_date_value(nil), do: nil

  defp posting_late_adjustment?(%{late_adjustment?: late_adjustment?}), do: late_adjustment?
  defp posting_late_adjustment?(_posting_date), do: false

  defp max_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp closable_finance_period(period_end_on) do
    with %FinanceReportingStart{} = reporting_start <- finance_reporting_start(),
         true <- Date.compare(period_end_on, reporting_start.starts_on) in [:eq, :gt],
         true <- finance_period_after_latest_close?(period_end_on) do
      {:ok, reporting_start}
    else
      _ -> {:error, "invalid_period"}
    end
  end

  defp finance_period_after_latest_close?(period_end_on) do
    case latest_finance_period_close() do
      nil ->
        true

      %FinancePeriodClose{period_end_on: latest_end_on} ->
        Date.compare(period_end_on, latest_end_on) == :gt
    end
  end

  defp latest_finance_period_close do
    FinancePeriodClose
    |> order_by([period_close], desc: period_close.period_end_on)
    |> limit(1)
    |> Repo.one()
  end

  defp start_finance_reporting!(operation, starts_on) do
    opening_cash_balances = opening_cash_balances_by_property()

    opening_credit_liability_cents =
      available_credit_total(starts_on) + active_credit_allocation_total()

    Repo.insert!(%FinanceReportingStart{
      operation_id: Map.fetch!(operation, "operation_id"),
      starts_on: starts_on,
      opening_credit_liability_cents: opening_credit_liability_cents
    })

    opening_cash_balances
    |> Enum.reject(fn {_property_id, amount_cents} -> amount_cents == 0 end)
    |> Enum.each(fn {property_id, amount_cents} ->
      Repo.insert!(%FinanceCashOpeningBalance{
        property_id: property_id,
        opening_held_cents: amount_cents
      })
    end)

    schedule_opening_credit_expiries(starts_on)
  end

  defp close_finance_period!(operation, reporting_start, period_end_on) do
    Repo.insert!(%FinancePeriodClose{
      operation_id: Map.fetch!(operation, "operation_id"),
      period_end_on: period_end_on
    })

    reporting_start.starts_on
    |> Date.range(period_end_on)
    |> Enum.each(fn date ->
      unless Repo.exists?(
               from report in FinanceClosedDailyReport,
                 where: report.report_date == ^date
             ) do
        data_json =
          reporting_start
          |> daily_report_data(date, "closed")
          |> Jason.encode!()

        Repo.insert!(%FinanceClosedDailyReport{
          report_date: date,
          data_json: data_json
        })
      end
    end)

    :ok
  end

  defp opening_cash_balances_by_property do
    RoomFundingAllocation
    |> join(:inner, [allocation], group in assoc(allocation, :group))
    |> join(:inner, [allocation, _group], room in assoc(allocation, :room))
    |> where([allocation, group, room], allocation.funding_type == ^@funding_cash)
    |> where([_allocation, group, room], group.status == ^@active and room.status == ^@active)
    |> group_by([_allocation, group, _room], group.property_id)
    |> select([allocation, group, _room], {
      group.property_id,
      coalesce(sum(allocation.amount_cents), 0)
    })
    |> Repo.all()
    |> Map.new()
  end

  defp schedule_opening_credit_expiries(starts_on) do
    CreditLot
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^starts_on)
    |> Repo.all()
    |> Enum.each(fn lot ->
      record_credit_expiry_adjustment(lot, lot.remaining_cents, starts_on)
    end)
  end

  defp record_cash_movement(
         posting_date,
         property_id,
         movement_type,
         amount_cents,
         operation,
         cash_funding_id \\ nil
       )

  defp record_cash_movement(
         posting_date,
         property_id,
         movement_type,
         amount_cents,
         operation,
         cash_funding_id
       ) do
    case posting_date_value(posting_date) do
      nil ->
        :ok

      _persisted_posting_date when amount_cents == 0 ->
        :ok

      persisted_posting_date ->
        Repo.insert!(%FinanceCashMovement{
          posting_date: persisted_posting_date,
          property_id: property_id,
          movement_type: movement_type,
          amount_cents: amount_cents,
          operation_id: Map.get(operation, "operation_id"),
          cash_funding_id: cash_funding_id,
          late_adjustment: posting_late_adjustment?(posting_date)
        })

        :ok
    end
  end

  defp record_cash_movements_by_group(
         posting_date,
         movement_type,
         amounts,
         operation,
         cash_funding_id
       ) do
    group_ids = amounts |> Enum.map(& &1.group_id) |> Enum.uniq()
    properties_by_group_id = properties_by_group_id(group_ids)

    amounts
    |> Enum.group_by(& &1.group_id)
    |> Enum.each(fn {group_id, group_amounts} ->
      amount_cents = sum_key(group_amounts, :amount_cents)

      record_cash_movement(
        posting_date,
        Map.fetch!(properties_by_group_id, group_id),
        movement_type,
        amount_cents,
        operation,
        cash_funding_id
      )
    end)
  end

  defp record_chargeback_cash_movements(posting_date, operation, cash_funding, held_reductions) do
    record_cash_movements_by_group(
      posting_date,
      "charged_back",
      held_reductions,
      operation,
      cash_funding.id
    )

    fallback_property_id =
      cash_funding
      |> Repo.preload(:group)
      |> Map.fetch!(:group)
      |> Map.fetch!(:property_id)

    [
      {"refunded", cash_funding.refunded_cents},
      {"retained", cash_funding.retained_cents},
      {"converted_to_credit", cash_funding.converted_to_credit_cents}
    ]
    |> Enum.each(fn {movement_type, total_cents} ->
      settled_cash_movement_amounts(
        cash_funding.id,
        movement_type,
        total_cents,
        fallback_property_id
      )
      |> Enum.each(fn %{property_id: property_id, amount_cents: amount_cents} ->
        record_cash_movement(
          posting_date,
          property_id,
          movement_type,
          -amount_cents,
          operation,
          cash_funding.id
        )

        record_cash_movement(
          posting_date,
          property_id,
          "charged_back",
          amount_cents,
          operation,
          cash_funding.id
        )
      end)
    end)
  end

  defp settled_cash_movement_amounts(_cash_funding_id, _movement_type, 0, _fallback_property_id),
    do: []

  defp settled_cash_movement_amounts(
         cash_funding_id,
         movement_type,
         total_cents,
         fallback_property_id
       ) do
    event_amounts =
      FinanceCashMovement
      |> where([movement], movement.cash_funding_id == ^cash_funding_id)
      |> where([movement], movement.movement_type == ^movement_type)
      |> group_by([movement], movement.property_id)
      |> select([movement], %{
        property_id: movement.property_id,
        amount_cents: coalesce(sum(movement.amount_cents), 0)
      })
      |> Repo.all()
      |> Enum.reject(&(&1.amount_cents == 0))

    event_total = sum_key(event_amounts, :amount_cents)
    fallback_cents = total_cents - event_total

    if fallback_cents == 0 do
      event_amounts
    else
      event_amounts ++ [%{property_id: fallback_property_id, amount_cents: fallback_cents}]
    end
  end

  defp record_credit_movement(posting_date, movement_type, amount_cents, operation, credit_lot_id) do
    case posting_date_value(posting_date) do
      nil ->
        :ok

      _persisted_posting_date when amount_cents == 0 ->
        :ok

      persisted_posting_date ->
        Repo.insert!(%FinanceCreditMovement{
          posting_date: persisted_posting_date,
          movement_type: movement_type,
          amount_cents: amount_cents,
          operation_id: Map.get(operation, "operation_id"),
          credit_lot_id: credit_lot_id,
          late_adjustment: posting_late_adjustment?(posting_date)
        })

        :ok
    end
  end

  defp record_credit_application_expiry_adjustment(_lot, 0, _posting_date, _operation), do: :ok

  defp record_credit_application_expiry_adjustment(lot, amount_cents, posting_date, operation) do
    case posting_date_value(posting_date) do
      nil ->
        :ok

      persisted_posting_date ->
        if Date.compare(lot.expires_on, persisted_posting_date) == :gt do
          record_credit_expiry_adjustment(lot, -amount_cents, posting_date)
        else
          record_credit_movement(posting_date, "expired", -amount_cents, operation, lot.id)
        end
    end
  end

  defp record_credit_expiry_adjustment(_lot, 0, _posting_date), do: :ok

  defp record_credit_expiry_adjustment(lot, amount_cents, posting_date) do
    persisted_posting_date = posting_date_value(posting_date)

    if not is_nil(persisted_posting_date) and
         Date.compare(lot.expires_on, persisted_posting_date) == :gt do
      Repo.insert!(%FinanceCreditMovement{
        posting_date: lot.expires_on,
        movement_type: "expired",
        amount_cents: amount_cents,
        operation_id: nil,
        credit_lot_id: lot.id,
        late_adjustment: false
      })
    end

    :ok
  end

  defp properties_by_group_id([]), do: %{}

  defp properties_by_group_id(group_ids) do
    Group
    |> where([group], group.id in ^group_ids)
    |> select([group], {group.id, group.property_id})
    |> Repo.all()
    |> Map.new()
  end

  defp daily_report_data(reporting_start, date, status) do
    {cash_entries, cash_late_adjustments} = cash_report_entries(date)
    {credit_entry, credit_late_adjustments} = credit_report_entry(reporting_start, date)

    %{
      date: Date.to_iso8601(date),
      status: status,
      cash: cash_entries,
      credit: credit_entry,
      late_adjustments: %{
        cash: cash_late_adjustments,
        credit: credit_late_adjustments
      }
    }
  end

  defp cash_report_entries(date) do
    opening_balances = finance_cash_opening_balances()
    movements = cash_movements_on_or_before(date)

    properties =
      (Map.keys(opening_balances) ++ Enum.map(movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    rows =
      Enum.map(properties, fn property_id ->
        previous_totals =
          movements
          |> Enum.filter(
            &(Date.compare(&1.posting_date, date) == :lt and &1.property_id == property_id)
          )
          |> movement_totals(@cash_movement_types)

        daily_ordinary_totals =
          movements
          |> Enum.filter(
            &(Date.compare(&1.posting_date, date) == :eq and &1.property_id == property_id and
                not &1.late_adjustment)
          )
          |> movement_totals(@cash_movement_types)

        daily_late_totals =
          movements
          |> Enum.filter(
            &(Date.compare(&1.posting_date, date) == :eq and &1.property_id == property_id and
                &1.late_adjustment)
          )
          |> movement_totals(@cash_movement_types)

        daily_totals =
          add_movement_totals(
            daily_ordinary_totals,
            daily_late_totals,
            @cash_movement_types
          )

        opening_held_cents =
          Map.get(opening_balances, property_id, 0) + cash_balance_delta(previous_totals)

        movements_map = cash_movements_map(daily_ordinary_totals)
        late_movements_map = cash_movements_map(daily_late_totals)
        closing_held_cents = opening_held_cents + cash_balance_delta(daily_totals)

        %{
          entry: %{
            property_id: property_id,
            opening_held_cents: opening_held_cents,
            movements: movements_map,
            closing_held_cents: closing_held_cents
          },
          late_adjustment: %{
            property_id: property_id,
            movements: late_movements_map
          }
        }
      end)

    cash_entries =
      rows
      |> Enum.reject(fn row ->
        empty_cash_report_entry?(row.entry, row.late_adjustment.movements)
      end)
      |> Enum.map(& &1.entry)

    cash_late_adjustments =
      rows
      |> Enum.reject(&empty_late_cash_adjustment?/1)
      |> Enum.map(& &1.late_adjustment)

    {cash_entries, cash_late_adjustments}
  end

  defp finance_cash_opening_balances do
    FinanceCashOpeningBalance
    |> select([balance], {balance.property_id, balance.opening_held_cents})
    |> Repo.all()
    |> Map.new()
  end

  defp cash_movements_on_or_before(date) do
    FinanceCashMovement
    |> where([movement], movement.posting_date <= ^date)
    |> Repo.all()
  end

  defp cash_balance_delta(totals) do
    Map.get(totals, "received", 0) +
      Map.get(totals, "transferred_in", 0) -
      Map.get(totals, "transferred_out", 0) -
      Map.get(totals, "refunded", 0) -
      Map.get(totals, "retained", 0) -
      Map.get(totals, "converted_to_credit", 0) -
      Map.get(totals, "reduced", 0) -
      Map.get(totals, "charged_back", 0)
  end

  defp cash_movements_map(totals) do
    %{
      received_cents: Map.get(totals, "received", 0),
      transferred_in_cents: Map.get(totals, "transferred_in", 0),
      transferred_out_cents: Map.get(totals, "transferred_out", 0),
      refunded_cents: Map.get(totals, "refunded", 0),
      retained_cents: Map.get(totals, "retained", 0),
      converted_to_credit_cents: Map.get(totals, "converted_to_credit", 0),
      reduced_cents: Map.get(totals, "reduced", 0),
      charged_back_cents: Map.get(totals, "charged_back", 0)
    }
  end

  defp empty_cash_report_entry?(entry, late_movements) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      all_zero_movements?(entry.movements) and all_zero_movements?(late_movements)
  end

  defp empty_late_cash_adjustment?(%{late_adjustment: late_adjustment}) do
    all_zero_movements?(late_adjustment.movements)
  end

  defp credit_report_entry(reporting_start, date) do
    movements = credit_movements_on_or_before(date)

    previous_totals =
      movements
      |> Enum.filter(&(Date.compare(&1.posting_date, date) == :lt))
      |> movement_totals(@credit_movement_types)

    daily_ordinary_totals =
      movements
      |> Enum.filter(&(Date.compare(&1.posting_date, date) == :eq and not &1.late_adjustment))
      |> movement_totals(@credit_movement_types)

    daily_late_totals =
      movements
      |> Enum.filter(&(Date.compare(&1.posting_date, date) == :eq and &1.late_adjustment))
      |> movement_totals(@credit_movement_types)

    daily_totals =
      add_movement_totals(
        daily_ordinary_totals,
        daily_late_totals,
        @credit_movement_types
      )

    opening_liability_cents =
      reporting_start.opening_credit_liability_cents + credit_liability_delta(previous_totals)

    movements_map = credit_movements_map(daily_ordinary_totals)
    late_movements_map = credit_movements_map(daily_late_totals)
    closing_liability_cents = opening_liability_cents + credit_liability_delta(daily_totals)

    {
      %{
        opening_liability_cents: opening_liability_cents,
        movements: movements_map,
        closing_liability_cents: closing_liability_cents
      },
      late_movements_map
    }
  end

  defp credit_movements_on_or_before(date) do
    FinanceCreditMovement
    |> where([movement], movement.posting_date <= ^date)
    |> Repo.all()
  end

  defp credit_liability_delta(totals) do
    Map.get(totals, "issued", 0) -
      Map.get(totals, "expired", 0) -
      Map.get(totals, "consumed", 0) -
      Map.get(totals, "revoked", 0) -
      Map.get(totals, "absorbed", 0)
  end

  defp credit_movements_map(totals) do
    %{
      issued_cents: Map.get(totals, "issued", 0),
      expired_cents: Map.get(totals, "expired", 0),
      consumed_cents: Map.get(totals, "consumed", 0),
      revoked_cents: Map.get(totals, "revoked", 0),
      absorbed_cents: Map.get(totals, "absorbed", 0)
    }
  end

  defp movement_totals(movements, movement_types) do
    initial_totals = Map.new(movement_types, &{&1, 0})

    Enum.reduce(movements, initial_totals, fn movement, totals ->
      Map.update!(totals, movement.movement_type, &(&1 + movement.amount_cents))
    end)
  end

  defp add_movement_totals(left_totals, right_totals, movement_types) do
    Map.new(movement_types, fn movement_type ->
      {movement_type,
       Map.get(left_totals, movement_type, 0) + Map.get(right_totals, movement_type, 0)}
    end)
  end

  defp all_zero_movements?(movements), do: Enum.all?(Map.values(movements), &(&1 == 0))

  defp reschedule_date(params, key) do
    case required_raw(params, key) do
      {:ok, raw_date} ->
        case parse_date(raw_date) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      {:error, _code} ->
        {:error, "invalid_operation"}
    end
  end

  defp non_negative_integer(params, key) do
    with {:ok, value} <- required_raw(params, key),
         true <- is_integer(value),
         true <- value >= 0 do
      {:ok, value}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp sum_key(values, key), do: Enum.reduce(values, 0, &(&2 + Map.fetch!(&1, key)))

  defp sum_struct_field(values, field) do
    Enum.reduce(values, 0, &(&2 + Map.fetch!(Map.from_struct(&1), field)))
  end

  defp available_credit_total(on_date) do
    CreditLot
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^on_date)
    |> select([lot], coalesce(sum(lot.remaining_cents), 0))
    |> Repo.one()
  end

  defp active_credit_allocation_total do
    RoomFundingAllocation
    |> join(:inner, [allocation], group in assoc(allocation, :group))
    |> join(:inner, [allocation, _group], room in assoc(allocation, :room))
    |> where([allocation, group, room], allocation.funding_type == ^@funding_credit)
    |> where([_allocation, group, room], group.status == ^@active and room.status == ^@active)
    |> select([allocation, _group, _room], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp credit_shortfall_total do
    CreditLot
    |> where([lot], lot.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      total + min(lot.unrecovered_clawback_cents, active_credit_allocation_total_for_lot(lot))
    end)
  end

  defp active_credit_allocation_total_for_lot(lot) do
    RoomFundingAllocation
    |> join(:inner, [allocation], group in assoc(allocation, :group))
    |> join(:inner, [allocation, _group], room in assoc(allocation, :room))
    |> where([allocation, _group, _room], allocation.credit_lot_id == ^lot.id)
    |> where([allocation, _group, _room], allocation.funding_type == ^@funding_credit)
    |> where([_allocation, group, room], group.status == ^@active and room.status == ^@active)
    |> select([allocation, _group, _room], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp sum_cash_funding_field(field) do
    CashFunding
    |> select([funding], coalesce(sum(field(funding, ^field)), 0))
    |> Repo.one()
  end

  defp cash_funding_group_id(cash_funding) do
    cash_funding
    |> Repo.preload(:group)
    |> Map.fetch!(:group)
    |> Map.fetch!(:group_id)
  end

  defp held_cash_by_group(cash_funding) do
    RoomFundingAllocation
    |> join(:inner, [allocation], group in Group, on: group.id == allocation.group_id)
    |> join(:inner, [allocation, _group], room in Room, on: room.id == allocation.room_id)
    |> where([allocation, _group, _room], allocation.cash_funding_id == ^cash_funding.id)
    |> where([allocation, _group, _room], allocation.funding_type == ^@funding_cash)
    |> where([_allocation, group, room], group.status == ^@active and room.status == ^@active)
    |> group_by([_allocation, group, _room], group.group_id)
    |> order_by([_allocation, group, _room], asc: group.group_id)
    |> select([allocation, group, _room], %{
      group_id: group.group_id,
      amount_cents: coalesce(sum(allocation.amount_cents), 0)
    })
    |> Repo.all()
  end

  defp applied(operation, attrs), do: {:applied, result(operation, "applied", attrs)}

  defp rejected(operation, code, attrs \\ %{}) do
    {:rejected, result(operation, "rejected", Map.put(attrs, :code, code))}
  end

  defp operation_id_conflict(operation_id) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: "operation_id_conflict"
    }
  end

  defp result(operation, status, attrs) do
    operation_id =
      if is_map(operation) do
        Map.get(operation, "operation_id")
      end

    %{
      operation_id: operation_id,
      status: status
    }
    |> Map.merge(attrs)
  end

  defp rememberable_operation_id(%{"operation_id" => operation_id})
       when is_binary(operation_id) do
    if String.trim(operation_id) == "" do
      :error
    else
      {:ok, operation_id}
    end
  end

  defp rememberable_operation_id(_operation), do: :error

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp decode_operation_result(%PartnerOperation{result_json: result_json}) do
    Jason.decode!(result_json)
  end

  defp canonical_json!(value), do: value |> canonical_json_iodata() |> IO.iodata_to_binary()

  defp canonical_json_iodata(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested_value} -> {to_string(key), nested_value} end)
      |> Enum.sort_by(fn {key, _nested_value} -> key end)
      |> Enum.map(fn {key, nested_value} ->
        [Jason.encode!(key), ?:, canonical_json_iodata(nested_value)]
      end)

    [?{, Enum.intersperse(entries, ?,), ?}]
  end

  defp canonical_json_iodata(value) when is_list(value) do
    [?[, value |> Enum.map(&canonical_json_iodata/1) |> Enum.intersperse(?,), ?]]
  end

  defp canonical_json_iodata(value), do: Jason.encode!(value)
end
