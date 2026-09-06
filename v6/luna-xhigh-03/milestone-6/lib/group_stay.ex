defmodule GroupStay do
  @moduledoc "The group reservation and deposit domain."

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query, only: [from: 2]

  alias GroupStay.{
    CashAllocation,
    CashPayment,
    CashPaymentSettlement,
    CreditAllocation,
    FinanceEvent,
    FinanceReporting,
    CreditLot,
    CreditLotContribution,
    Group,
    Operation,
    Repo
  }

  @active_status "active"
  @cancelled_status "cancelled"
  @rate_plans ["flexible", "advance_purchase"]
  @policy_cutover ~D[2027-01-01]

  @doc "Processes partner operations in order and returns one result per operation."
  def process_batch(operations) when is_list(operations),
    do: Enum.map(operations, &process_operation/1)

  @doc "Returns a public group representation or `:not_found`."
  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :not_found
      group -> {:ok, public_group(group)}
    end
  end

  @doc "Returns a previously remembered operation result or `:not_found`."
  def get_operation(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> :not_found
      operation -> {:ok, Jason.decode!(operation.result_json)}
    end
  end

  @doc "Returns a current statement for a durably recorded cash payment."
  def get_payment(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil -> :not_found
      operation -> payment_statement(operation)
    end
  end

  @doc "Returns the guest's unexpired, available hotel credit as of a date."
  def guest_credit(guest_id, as_of \\ Date.utc_today()) do
    lots = available_credit_lots(guest_id, as_of)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      "lots" => Enum.map(lots, &public_credit_lot/1)
    }
  end

  @doc "Returns accounting totals as of a date for credit expiry reporting."
  def ledger(as_of \\ Date.utc_today()) do
    groups = Repo.all(Group)

    active_group_ids =
      MapSet.new(for group <- groups, group.status == @active_status, do: group.group_id)

    active_credit =
      Repo.all(CreditAllocation)
      |> Enum.reduce(0, fn allocation, total ->
        if MapSet.member?(active_group_ids, allocation.group_id),
          do: total + allocation.amount_cents,
          else: total
      end)

    available_credit =
      Repo.all(CreditLot)
      |> Enum.reduce(0, fn lot, total ->
        if lot.remaining_cents > 0 and Date.compare(credit_issued_on(lot), as_of) in [:lt, :eq] and
             Date.compare(lot.expires_on, as_of) in [:eq, :gt],
           do: total + lot.remaining_cents,
           else: total
      end)

    Enum.reduce(
      groups,
      %{
        "cash_held_cents" => 0,
        "cash_refunded_cents" => 0,
        "cash_retained_cents" => 0,
        "cash_converted_to_credit_cents" => 0,
        "cash_reduced_cents" => 0,
        "cash_charged_back_cents" => 0,
        "credit_liability_cents" => available_credit + active_credit,
        "credit_shortfall_cents" => current_credit_shortfall()
      },
      fn group, totals ->
        held = if group.status == @active_status, do: cash_paid(group), else: 0

        %{
          "cash_held_cents" => totals["cash_held_cents"] + held,
          "cash_refunded_cents" => totals["cash_refunded_cents"] + (group.refunded_cents || 0),
          "cash_retained_cents" => totals["cash_retained_cents"] + (group.retained_cents || 0),
          "cash_converted_to_credit_cents" =>
            totals["cash_converted_to_credit_cents"] + (group.cash_converted_to_credit_cents || 0),
          "cash_reduced_cents" => totals["cash_reduced_cents"] + (group.cash_reduced_cents || 0),
          "cash_charged_back_cents" =>
            totals["cash_charged_back_cents"] + (group.cash_charged_back_cents || 0),
          "credit_liability_cents" => totals["credit_liability_cents"],
          "credit_shortfall_cents" => totals["credit_shortfall_cents"]
        }
      end
    )
  end

  @doc "Returns the immutable daily finance report for a reporting date."
  def daily_finance_report(date) do
    case Repo.one(FinanceReporting) do
      nil ->
        {:error, "report_not_available"}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, "report_not_available"}
        else
          {:ok, build_daily_finance_report(reporting, date)}
        end
    end
  end

  @cash_movement_fields [
    "received_cents",
    "transferred_in_cents",
    "transferred_out_cents",
    "refunded_cents",
    "retained_cents",
    "converted_to_credit_cents",
    "reduced_cents",
    "charged_back_cents"
  ]

  @credit_movement_fields [
    "issued_cents",
    "expired_cents",
    "consumed_cents",
    "revoked_cents",
    "absorbed_cents"
  ]

  defp build_daily_finance_report(reporting, date) do
    events = Repo.all(from event in FinanceEvent, order_by: [asc: event.operation_id])
    prior_events = Enum.filter(events, &(Date.compare(&1.posting_on, date) == :lt))
    current_events = Enum.filter(events, &(Date.compare(&1.posting_on, date) == :eq))

    opening_cash = add_cash_events(Jason.decode!(reporting.opening_cash_json), prior_events)

    opening_credit =
      reporting.opening_credit_liability_cents +
        credit_net(prior_events) -
        expiry_total_before(reporting, events, date)

    current_cash_movements = cash_events(current_events)
    current_credit_movements = credit_events(current_events)
    current_expired = expiry_for_date(reporting, events, date)

    current_credit_movements =
      Map.update!(current_credit_movements, "expired_cents", &(&1 + current_expired))

    cash_properties =
      (Map.keys(opening_cash) ++ Map.keys(current_cash_movements))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      cash_properties
      |> Enum.map(fn property_id ->
        opening_held_cents = Map.get(opening_cash, property_id, 0)
        movements = Map.get(current_cash_movements, property_id, empty_cash_movement())
        closing_held_cents = opening_held_cents + cash_net(movements)

        {property_id,
         %{
           "property_id" => property_id,
           "opening_held_cents" => opening_held_cents,
           "movements" => movements,
           "closing_held_cents" => closing_held_cents
         }}
      end)
      |> Enum.reject(fn {_property_id, entry} ->
        entry["opening_held_cents"] == 0 and entry["closing_held_cents"] == 0 and
          cash_net(entry["movements"]) == 0 and
          Enum.all?(Map.values(entry["movements"]), &(&1 == 0))
      end)
      |> Enum.map(&elem(&1, 1))

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash,
      "credit" => %{
        "opening_liability_cents" => opening_credit,
        "movements" => current_credit_movements,
        "closing_liability_cents" => opening_credit + credit_net_map(current_credit_movements)
      }
    }
  end

  defp finance_snapshot do
    groups = Repo.all(Group)

    group_map =
      Map.new(groups, fn group ->
        {group.group_id,
         %{
           "property_id" => group.property_id,
           "status" => group.status,
           "cash_held_cents" => if(group.status == @active_status, do: cash_paid(group), else: 0),
           "refunded_cents" => group.refunded_cents || 0,
           "retained_cents" => group.retained_cents || 0,
           "converted_to_credit_cents" => group.cash_converted_to_credit_cents || 0,
           "policy_version" => policy_version(group),
           "arrival_on" => group.arrival_on
         }}
      end)

    cash_by_payment_group =
      Repo.all(CashAllocation)
      |> Enum.filter(
        &(is_binary(&1.payment_operation_id) &&
            Map.get(group_map, &1.group_id, %{})["status"] == @active_status)
      )
      |> Enum.group_by(fn allocation ->
        {allocation.payment_operation_id, allocation.group_id}
      end)
      |> Map.new(fn {key, allocations} ->
        {key, Enum.reduce(allocations, 0, &(&1.amount_cents + &2))}
      end)

    settlements =
      Repo.all(CashPaymentSettlement)
      |> Map.new(fn settlement ->
        {{settlement.payment_operation_id, settlement.group_id},
         %{
           "refunded_cents" => settlement.refunded_cents || 0,
           "retained_cents" => settlement.retained_cents || 0,
           "converted_to_credit_cents" => settlement.converted_to_credit_cents || 0
         }}
      end)

    lots =
      Repo.all(CreditLot)
      |> Map.new(fn lot ->
        {lot.id,
         %{
           "remaining_cents" => lot.remaining_cents || 0,
           "unrecovered_clawback_cents" => lot.unrecovered_clawback_cents || 0,
           "expires_on" => lot.expires_on
         }}
      end)

    active_group_ids =
      group_map
      |> Enum.filter(fn {_group_id, group} -> group["status"] == @active_status end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    active_credit_by_lot =
      Repo.all(CreditAllocation)
      |> Enum.filter(&MapSet.member?(active_group_ids, &1.group_id))
      |> Enum.group_by(& &1.credit_lot_id)
      |> Map.new(fn {lot_id, allocations} ->
        {lot_id, Enum.reduce(allocations, 0, &(&1.amount_cents + &2))}
      end)

    %{
      groups: group_map,
      cash_by_payment_group: cash_by_payment_group,
      settlements: settlements,
      lots: lots,
      active_credit_by_lot: active_credit_by_lot,
      active_credit_liability_cents:
        Enum.reduce(active_credit_by_lot, 0, fn {_id, amount}, total -> total + amount end)
    }
  end

  defp cash_by_property(snapshot) do
    Enum.reduce(snapshot.groups, %{}, fn {_group_id, group}, properties ->
      if group["cash_held_cents"] > 0 do
        Map.update(
          properties,
          group["property_id"],
          group["cash_held_cents"],
          &(&1 + group["cash_held_cents"])
        )
      else
        properties
      end
    end)
  end

  defp opening_credit_lots(snapshot, starts_on) do
    snapshot.lots
    |> Enum.filter(fn {_lot_id, lot} ->
      lot["remaining_cents"] > 0 and Date.compare(lot["expires_on"], starts_on) in [:eq, :gt]
    end)
    |> Enum.map(fn {lot_id, lot} ->
      %{
        "lot_id" => lot_id,
        "remaining_cents" => lot["remaining_cents"],
        "expires_on" => Date.to_iso8601(lot["expires_on"])
      }
    end)
    |> Enum.sort_by(&{&1["expires_on"], &1["lot_id"]})
  end

  defp record_finance_event!(operation, result, reporting, before_snapshot, after_snapshot) do
    posting_on = finance_posting_on(operation, reporting.starts_on)
    changes = credit_lot_changes(before_snapshot, after_snapshot)

    event = %FinanceEvent{
      operation_id: operation_id_value(operation),
      posting_on: posting_on,
      cash_movements_json:
        Jason.encode!(finance_cash_movements(operation, result, before_snapshot, after_snapshot)),
      credit_movements_json:
        Jason.encode!(
          finance_credit_movements(
            operation,
            result,
            reporting,
            before_snapshot,
            after_snapshot,
            posting_on
          )
        ),
      credit_lot_changes_json: Jason.encode!(changes)
    }

    case Repo.insert(event) do
      {:ok, _event} -> :ok
      {:error, changeset} -> Repo.rollback({:finance_event_insert_failed, changeset})
    end
  end

  defp reporting_date(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_reporting_date"}
        end

      _ ->
        {:error, "invalid_reporting_date"}
    end
  end

  defp finance_posting_on(operation, starts_on) do
    case operation_occurred_on(operation) do
      nil ->
        starts_on

      occurred_on ->
        if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
    end
  end

  defp operation_occurred_on(operation) do
    case Map.get(operation, "occurred_on") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          {:error, _reason} -> nil
        end

      _ ->
        nil
    end
  end

  defp empty_cash_movement, do: Map.new(@cash_movement_fields, &{&1, 0})
  defp empty_credit_movement, do: Map.new(@credit_movement_fields, &{&1, 0})

  defp add_cash_movement(movements, _property_id, _field, 0), do: movements

  defp add_cash_movement(movements, property_id, field, amount) do
    movement = Map.get(movements, property_id, empty_cash_movement())
    Map.put(movements, property_id, Map.update!(movement, field, &(&1 + amount)))
  end

  defp add_credit_movement(movements, _field, 0), do: movements

  defp add_credit_movement(movements, field, amount),
    do: Map.update!(movements, field, &(&1 + amount))

  defp cash_net(movement) do
    movement["received_cents"] + movement["transferred_in_cents"] -
      movement["transferred_out_cents"] - movement["refunded_cents"] -
      movement["retained_cents"] - movement["converted_to_credit_cents"] -
      movement["reduced_cents"] - movement["charged_back_cents"]
  end

  defp credit_net_map(movement) do
    movement["issued_cents"] - movement["expired_cents"] - movement["consumed_cents"] -
      movement["revoked_cents"] - movement["absorbed_cents"]
  end

  defp credit_net(events), do: events |> credit_events() |> credit_net_map()

  defp cash_events(events) do
    Enum.reduce(events, %{}, fn event, movements ->
      event.cash_movements_json
      |> Jason.decode!()
      |> Enum.reduce(movements, fn {property_id, movement}, movements ->
        Enum.reduce(@cash_movement_fields, movements, fn field, movements ->
          add_cash_movement(movements, property_id, field, movement[field] || 0)
        end)
      end)
    end)
  end

  defp credit_events(events) do
    Enum.reduce(events, empty_credit_movement(), fn event, movements ->
      event.credit_movements_json
      |> Jason.decode!()
      |> Enum.reduce(movements, fn {field, amount}, movements ->
        add_credit_movement(movements, field, amount || 0)
      end)
    end)
  end

  defp add_cash_events(opening, events) do
    events
    |> cash_events()
    |> Enum.reduce(opening, fn {property_id, movement}, opening ->
      Map.put(opening, property_id, Map.get(opening, property_id, 0) + cash_net(movement))
    end)
  end

  defp finance_cash_movements(operation, result, before, after_snapshot) do
    case operation_type(operation) do
      "record_cash_payment" ->
        group_id = result["group_id"]
        amount = result["amount_cents"] || 0

        property_id =
          property_for_group(after_snapshot, group_id) || property_for_group(before, group_id)

        add_cash_movement(%{}, property_id, "received_cents", amount)

      "transfer_deposit" ->
        source_group_id = operation["source_group_id"]
        destination_group_id = operation["destination_group_id"]
        source_delta = cash_held_delta(before, after_snapshot, source_group_id)
        destination_delta = cash_held_delta(before, after_snapshot, destination_group_id)

        movements =
          add_cash_movement(
            %{},
            property_for_group(before, source_group_id),
            "transferred_out_cents",
            max(source_delta, 0)
          )

        add_cash_movement(
          movements,
          property_for_group(after_snapshot, destination_group_id),
          "transferred_in_cents",
          max(-destination_delta, 0)
        )

      type when type in ["cancel_group", "cancel_rooms"] ->
        cash_cumulative_movements(before, after_snapshot, false)

      "reduce_cash_payment" ->
        cash_payment_removal_movements(
          operation["payment_operation_id"],
          before,
          after_snapshot,
          "reduced_cents"
        )

      "charge_back_payment" ->
        movements =
          cash_payment_removal_movements(
            operation["payment_operation_id"],
            before,
            after_snapshot,
            "charged_back_cents"
          )

        cash_chargeback_settlement_movements(movements, before, after_snapshot)

      _ ->
        %{}
    end
  end

  defp cash_cumulative_movements(before, after_snapshot, chargeback?) do
    group_ids = (Map.keys(before.groups) ++ Map.keys(after_snapshot.groups)) |> Enum.uniq()

    Enum.reduce(group_ids, %{}, fn group_id, movements ->
      property_id =
        property_for_group(after_snapshot, group_id) || property_for_group(before, group_id)

      before_group = Map.get(before.groups, group_id, %{})
      after_group = Map.get(after_snapshot.groups, group_id, %{})

      Enum.reduce(
        [
          {"refunded_cents", "refunded_cents"},
          {"retained_cents", "retained_cents"},
          {"converted_to_credit_cents", "converted_to_credit_cents"}
        ],
        movements,
        fn {source, field}, movements ->
          delta = Map.get(after_group, source, 0) - Map.get(before_group, source, 0)
          movements = add_cash_movement(movements, property_id, field, delta)

          if chargeback? and delta < 0,
            do: add_cash_movement(movements, property_id, "charged_back_cents", -delta),
            else: movements
        end
      )
    end)
  end

  defp cash_payment_removal_movements(payment_operation_id, before, after_snapshot, field) do
    keys =
      (Map.keys(before.cash_by_payment_group) ++ Map.keys(after_snapshot.cash_by_payment_group))
      |> Enum.uniq()

    Enum.reduce(keys, %{}, fn {payment_id, group_id}, movements ->
      if payment_id == payment_operation_id do
        before_amount = Map.get(before.cash_by_payment_group, {payment_id, group_id}, 0)
        after_amount = Map.get(after_snapshot.cash_by_payment_group, {payment_id, group_id}, 0)

        property_id =
          property_for_group(before, group_id) || property_for_group(after_snapshot, group_id)

        add_cash_movement(movements, property_id, field, max(before_amount - after_amount, 0))
      else
        movements
      end
    end)
  end

  defp cash_chargeback_settlement_movements(movements, before, after_snapshot) do
    keys = (Map.keys(before.settlements) ++ Map.keys(after_snapshot.settlements)) |> Enum.uniq()

    Enum.reduce(keys, movements, fn {payment_id, group_id}, movements ->
      before_settlement = Map.get(before.settlements, {payment_id, group_id}, %{})
      after_settlement = Map.get(after_snapshot.settlements, {payment_id, group_id}, %{})

      property_id =
        property_for_group(before, group_id) || property_for_group(after_snapshot, group_id)

      Enum.reduce(
        ["refunded_cents", "retained_cents", "converted_to_credit_cents"],
        movements,
        fn field, movements ->
          delta = Map.get(after_settlement, field, 0) - Map.get(before_settlement, field, 0)
          movements = add_cash_movement(movements, property_id, field, delta)

          if delta < 0,
            do: add_cash_movement(movements, property_id, "charged_back_cents", -delta),
            else: movements
        end
      )
    end)
  end

  defp cash_held_delta(before, after_snapshot, group_id) do
    Map.get(before.groups, group_id, %{})["cash_held_cents"] -
      Map.get(after_snapshot.groups, group_id, %{})["cash_held_cents"]
  end

  defp property_for_group(snapshot, group_id),
    do: Map.get(snapshot.groups, group_id, %{})["property_id"]

  defp finance_credit_movements(operation, result, _reporting, before, after_snapshot, posting_on) do
    movements = empty_credit_movement()
    movements = add_credit_movement(movements, "issued_cents", result["credit_issued_cents"] || 0)
    changes = credit_lot_changes(before, after_snapshot)

    case operation_type(operation) do
      type when type in ["cancel_group", "cancel_rooms"] ->
        removed_active = Enum.reduce(changes, 0, &(&2 + max(-&1["active_delta"], 0)))
        absorbed = Enum.reduce(changes, 0, &(&2 + max(-&1["unrecovered_delta"], 0)))

        new_available =
          Enum.reduce(changes, 0, fn change, total ->
            if is_nil(change["before_lot_id"]),
              do: total + max(change["available_delta"], 0),
              else: total
          end)

        restored =
          max(Enum.reduce(changes, 0, &(&2 + max(&1["available_delta"], 0))) - new_available, 0)

        if cancellation_refundable?(operation, before) do
          expired = max(removed_active - absorbed - restored, 0)

          movements
          |> add_credit_movement("absorbed_cents", absorbed)
          |> add_credit_movement("expired_cents", expired)
        else
          add_credit_movement(movements, "consumed_cents", removed_active)
        end

      "charge_back_payment" ->
        revoked =
          Enum.reduce(changes, 0, fn change, total ->
            expires_on = Date.from_iso8601!(change["expires_on"])

            if Date.compare(posting_on, expires_on) in [:lt, :eq],
              do: total + max(-change["available_delta"], 0),
              else: total
          end)

        add_credit_movement(movements, "revoked_cents", revoked)

      _ ->
        movements
    end
  end

  defp cancellation_refundable?(operation, snapshot) do
    group_id = operation["group_id"]
    group = Map.get(snapshot.groups, group_id)
    occurred_on = operation_occurred_on(operation)

    if group && occurred_on do
      case group["policy_version"] do
        "flex-14" -> Date.compare(occurred_on, Date.add(group["arrival_on"], -14)) in [:lt, :eq]
        "flex-30" -> Date.compare(occurred_on, Date.add(group["arrival_on"], -30)) in [:lt, :eq]
        _ -> false
      end
    else
      false
    end
  end

  defp credit_lot_changes(before, after_snapshot) do
    lot_ids = (Map.keys(before.lots) ++ Map.keys(after_snapshot.lots)) |> Enum.uniq()

    Enum.flat_map(lot_ids, fn lot_id ->
      before_lot = Map.get(before.lots, lot_id)
      after_lot = Map.get(after_snapshot.lots, lot_id)
      before_available = if before_lot, do: before_lot["remaining_cents"], else: 0
      after_available = if after_lot, do: after_lot["remaining_cents"], else: 0
      before_unrecovered = if before_lot, do: before_lot["unrecovered_clawback_cents"], else: 0
      after_unrecovered = if after_lot, do: after_lot["unrecovered_clawback_cents"], else: 0
      before_active = Map.get(before.active_credit_by_lot, lot_id, 0)
      after_active = Map.get(after_snapshot.active_credit_by_lot, lot_id, 0)
      expires_on = (after_lot || before_lot)["expires_on"]

      if before_available == after_available and before_active == after_active and
           before_unrecovered == after_unrecovered do
        []
      else
        [
          %{
            "lot_id" => lot_id,
            "before_lot_id" => if(before_lot, do: lot_id, else: nil),
            "available_delta" => after_available - before_available,
            "active_delta" => after_active - before_active,
            "unrecovered_delta" => after_unrecovered - before_unrecovered,
            "expires_on" => Date.to_iso8601(expires_on)
          }
        ]
      end
    end)
  end

  defp expiry_total_before(reporting, events, date) do
    automatic_expiry_by_date(reporting, events)
    |> Enum.reduce(0, fn {expiry_date, amount}, total ->
      if Date.compare(expiry_date, reporting.starts_on) in [:eq, :gt] and
           Date.compare(expiry_date, date) == :lt,
         do: total + amount,
         else: total
    end)
  end

  defp expiry_for_date(reporting, events, date) do
    if Date.compare(date, reporting.starts_on) in [:eq, :gt],
      do: Map.get(automatic_expiry_by_date(reporting, events), date, 0),
      else: 0
  end

  defp automatic_expiry_by_date(reporting, events) do
    opening_lots =
      reporting.opening_credit_lots_json
      |> Jason.decode!()
      |> Map.new(fn lot ->
        {lot["lot_id"], {lot["remaining_cents"], Date.from_iso8601!(lot["expires_on"])}}
      end)

    lot_records =
      Enum.reduce(events, opening_lots, fn event, lots ->
        event.credit_lot_changes_json
        |> Jason.decode!()
        |> Enum.reduce(lots, fn change, lots ->
          lot_id = change["lot_id"]
          expires_on = Date.from_iso8601!(change["expires_on"])
          {_, existing_expires_on} = Map.get(lots, lot_id, {0, expires_on})
          Map.put_new(lots, lot_id, {0, existing_expires_on})
        end)
      end)

    Enum.reduce(lot_records, %{}, fn {lot_id, {initial_available, expires_on}}, expiry_dates ->
      available_at_expiry =
        initial_available +
          Enum.reduce(events, 0, fn event, total ->
            if Date.compare(event.posting_on, expires_on) in [:lt, :eq] do
              event.credit_lot_changes_json
              |> Jason.decode!()
              |> Enum.reduce(total, fn change, total ->
                if change["lot_id"] == lot_id, do: total + change["available_delta"], else: total
              end)
            else
              total
            end
          end)

      amount = max(available_at_expiry, 0)
      expiry_date = Date.add(expires_on, 1)

      if amount > 0,
        do: Map.update(expiry_dates, expiry_date, amount, &(&1 + amount)),
        else: expiry_dates
    end)
  end

  defp process_operation(operation) do
    with {:ok, operation_id} <- operation_id(operation),
         {:ok, payload_json} <- Jason.encode(operation) do
      case Repo.transaction(
             fn -> process_durable_operation(operation, operation_id, payload_json) end,
             mode: :immediate
           ) do
        {:ok, result} -> result
        {:error, reason} -> raise_transaction_error(reason)
      end
    else
      {:error, _reason} ->
        {_status, result} = rejected(operation, "invalid_operation")
        result
    end
  end

  defp process_durable_operation(operation, operation_id, payload_json) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      %Operation{} = remembered ->
        if equivalent_payload?(remembered.payload_json, payload_json) do
          Jason.decode!(remembered.result_json)
        else
          {_status, result} = rejected(operation, "operation_id_conflict")
          result
        end

      nil ->
        reporting = Repo.one(FinanceReporting)
        before_snapshot = if reporting, do: finance_snapshot()
        {status, result} = apply_operation(operation)

        if (status == :applied and reporting) &&
             operation_type(operation) != "start_finance_reporting" do
          record_finance_event!(operation, result, reporting, before_snapshot, finance_snapshot())
        end

        remember_operation(operation, operation_id, payload_json, result)
        result
    end
  end

  defp remember_operation(operation, operation_id, payload_json, result) do
    case Repo.insert(%Operation{
           operation_id: operation_id,
           type: audit_type(operation),
           payload_json: payload_json,
           result_json: Jason.encode!(result)
         }) do
      {:ok, _record} -> :ok
      {:error, changeset} -> Repo.rollback({:operation_insert_failed, changeset})
    end
  end

  defp equivalent_payload?(remembered_payload_json, payload_json) do
    with {:ok, remembered_payload} <- Jason.decode(remembered_payload_json),
         {:ok, payload} <- Jason.decode(payload_json) do
      normalize_json(remembered_payload) == normalize_json(payload)
    else
      _ -> false
    end
  end

  defp normalize_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {key, normalize_json(nested_value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)
  defp normalize_json(value), do: value

  defp raise_transaction_error(reason),
    do: raise("partner operation transaction failed: #{inspect(reason)}")

  defp audit_type(operation) do
    case operation_type(operation) do
      type when is_binary(type) -> type
      nil -> nil
      type -> Jason.encode!(type)
    end
  end

  defp apply_operation(operation) do
    case operation_type(operation) do
      "start_finance_reporting" -> apply_start_finance_reporting(operation)
      "open_group" -> apply_open_group(operation)
      "record_cash_payment" -> apply_cash_payment(operation)
      "reschedule_group" -> apply_reschedule(operation)
      "cancel_group" -> apply_cancellation(operation)
      "cancel_rooms" -> apply_cancel_rooms(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      "transfer_deposit" -> apply_deposit_transfer(operation)
      "reduce_cash_payment" -> apply_reduce_cash_payment(operation)
      "charge_back_payment" -> apply_charge_back_payment(operation)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp apply_start_finance_reporting(operation) do
    case Repo.one(FinanceReporting) do
      %FinanceReporting{} ->
        rejected(operation, "reporting_already_started")

      nil ->
        case reporting_date(operation, "starts_on") do
          {:ok, starts_on} ->
            snapshot = finance_snapshot()
            opening_cash = cash_by_property(snapshot)
            opening_credit_lots = opening_credit_lots(snapshot, starts_on)

            {:ok, _reporting} =
              Repo.insert(%FinanceReporting{
                id: 1,
                starts_on: starts_on,
                opening_cash_json: Jason.encode!(opening_cash),
                opening_credit_liability_cents:
                  Enum.reduce(opening_credit_lots, 0, &(&1["remaining_cents"] + &2)) +
                    snapshot.active_credit_liability_cents,
                opening_credit_lots_json: Jason.encode!(opening_credit_lots)
              })

            {:applied,
             %{
               "operation_id" => operation_id_value(operation),
               "status" => "applied",
               "starts_on" => Date.to_iso8601(starts_on)
             }}

          {:error, _code} ->
            rejected(operation, "invalid_reporting_date")
        end
    end
  end

  defp apply_open_group(operation) do
    with {:ok, _operation_id} <- operation_id(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id") do
      case Repo.get(Group, group_id) do
        %Group{} -> rejected(operation, "group_already_exists")
        nil -> build_open_group(operation, group_id)
      end
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp build_open_group(operation, group_id) do
    with {:ok, booked_on} <- required_date(operation, "occurred_on"),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- valid_rate_plan(operation),
         {:ok, rooms, lodging_total_cents, deposit_due_cents} <-
           calculate_rooms(operation, arrival_on, departure_on, rate_plan) do
      group = %Group{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version(rate_plan, booked_on),
        status: @active_status,
        rooms_json: Jason.encode!(rooms),
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
        revision: 1
      }

      case Repo.insert(group) do
        {:ok, _group} ->
          {:applied,
           %{
             "operation_id" => operation_id_value(operation),
             "status" => "applied",
             "group_id" => group_id,
             "deposit_due_cents" => deposit_due_cents,
             "revision" => 1
           }}

        {:error, _changeset} ->
          rejected(operation, "group_already_exists")
      end
    else
      {:error, code} -> rejected(operation, code)
      :invalid_stay -> rejected(operation, "invalid_stay")
    end
  end

  defp apply_cash_payment(operation) do
    apply_to_existing_group(operation, fn group ->
      if group.status != @active_status do
        rejected(operation, "group_not_active")
      else
        with {:ok, _occurred_on} <- required_date(operation, "occurred_on"),
             {:ok, amount_cents} <- payment_amount(operation),
             outstanding_deposit_cents <- outstanding_deposit(group),
             :ok <- payment_fits(amount_cents, outstanding_deposit_cents) do
          ensure_group_accounting(group)
          allocate_cash_funding(group, operation_id_value(operation), amount_cents)
          {:ok, payment} = insert_cash_payment(operation_id_value(operation), group, amount_cents)
          {:ok, updated_group} = refresh_group(group, revision: group.revision + 1)

          {:applied,
           %{
             "operation_id" => operation_id_value(operation),
             "status" => "applied",
             "group_id" => updated_group.group_id,
             "amount_cents" => payment.recorded_cents,
             "outstanding_deposit_cents" => outstanding_deposit(updated_group),
             "revision" => updated_group.revision
           }}
        else
          {:error, code} -> rejected(operation, code)
          :payment_exceeds_outstanding -> rejected(operation, "payment_exceeds_outstanding")
        end
      end
    end)
  end

  defp apply_reschedule(operation) do
    apply_to_existing_group(operation, fn group ->
      if group.status != @active_status do
        rejected(operation, "group_not_active")
      else
        with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
             {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
             :ok <- reschedule_date_is_valid(occurred_on, new_arrival_on) do
          day_shift = Date.diff(new_arrival_on, group.arrival_on)
          new_departure_on = Date.add(group.departure_on, day_shift)

          {:ok, updated_group} =
            update_group(group, %{
              arrival_on: new_arrival_on,
              departure_on: new_departure_on,
              revision: group.revision + 1
            })

          {:applied,
           %{
             "operation_id" => operation_id_value(operation),
             "status" => "applied",
             "group_id" => updated_group.group_id,
             "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
             "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
             "policy_version" => policy_version(updated_group),
             "refundable_until" => refundable_until_json(updated_group),
             "revision" => updated_group.revision
           }}
        else
          {:error, code} -> rejected(operation, code)
          :invalid_stay -> rejected(operation, "invalid_stay")
        end
      end
    end)
  end

  defp apply_cancellation(operation) do
    apply_to_existing_group(operation, fn group ->
      if group.status != @active_status do
        rejected(operation, "group_not_active")
      else
        with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
             {:ok, refund_method} <- refund_method(operation) do
          refundable? = refundable?(group, occurred_on)

          if refund_method == "hotel_credit" and not refundable?,
            do: rejected(operation, "refund_method_not_available"),
            else:
              settle_selected_rooms(
                operation,
                group,
                active_room_ids(group),
                occurred_on,
                refund_method,
                refundable?
              )
        else
          {:error, code} -> rejected(operation, code)
        end
      end
    end)
  end

  defp apply_cancel_rooms(operation) do
    apply_to_existing_group(operation, fn group ->
      if group.status != @active_status do
        rejected(operation, "group_not_active")
      else
        with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
             {:ok, refund_method} <- refund_method(operation),
             {:ok, room_ids} <- requested_room_ids(operation, group) do
          refundable? = refundable?(group, occurred_on)

          if refund_method == "hotel_credit" and not refundable?,
            do: rejected(operation, "refund_method_not_available"),
            else:
              settle_selected_rooms(
                operation,
                group,
                room_ids,
                occurred_on,
                refund_method,
                refundable?
              )
        else
          {:error, code} -> rejected(operation, code)
        end
      end
    end)
  end

  defp settle_selected_rooms(
         operation,
         group,
         selected_room_ids,
         occurred_on,
         refund_method,
         refundable?
       ) do
    ensure_group_accounting(group)
    selected_room_ids = order_room_ids(group, selected_room_ids)
    cash_allocations = cash_allocations_for_rooms(group.group_id, selected_room_ids)
    credit_allocations = credit_allocations_for_rooms(group.group_id, selected_room_ids)
    cash_cents = Enum.reduce(cash_allocations, 0, &(&1.amount_cents + &2))

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      settle_cash_for_rooms(
        operation,
        group,
        cash_allocations,
        occurred_on,
        refund_method,
        refundable?,
        cash_cents
      )

    settle_credit_for_rooms(credit_allocations, occurred_on, refundable?)
    delete_cash_allocations(cash_allocations)
    mark_rooms_cancelled(group, selected_room_ids)

    remaining_room_ids = active_room_ids(group) -- selected_room_ids

    {:ok, updated_group} =
      refresh_group(group,
        status: if(remaining_room_ids == [], do: @cancelled_status, else: @active_status),
        refunded_cents: (group.refunded_cents || 0) + refunded_cents,
        retained_cents: (group.retained_cents || 0) + retained_cents,
        cash_converted_to_credit_cents:
          (group.cash_converted_to_credit_cents || 0) + converted_cents,
        revision: group.revision + 1
      )

    result = %{
      "operation_id" => operation_id_value(operation),
      "status" => "applied",
      "group_id" => updated_group.group_id,
      "refunded_cents" => refunded_cents,
      "retained_cents" => retained_cents,
      "credit_issued_cents" => credit_issued_cents,
      "revision" => updated_group.revision
    }

    result =
      if operation_type(operation) == "cancel_rooms",
        do: Map.put(result, "cancelled_room_ids", selected_room_ids),
        else: result

    {:applied, result}
  end

  defp settle_cash_for_rooms(
         operation,
         group,
         allocations,
         occurred_on,
         refund_method,
         refundable?,
         cash_cents
       ) do
    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      cond do
        refundable? and refund_method == "cash" ->
          {cash_cents, 0, 0, 0}

        refundable? and refund_method == "hotel_credit" ->
          credit_issued_cents = cash_cents + round_percentage(cash_cents, 10, 100)

          if credit_issued_cents > 0 do
            lot =
              issue_credit_lot(
                group.guest_id,
                operation_id_value(operation),
                credit_issued_cents,
                occurred_on
              )

            add_credit_lot_contributions(lot, ordered_cash_sources(allocations), cash_cents)
          end

          {0, 0, cash_cents, credit_issued_cents}

        true ->
          {0, cash_cents, 0, 0}
      end

    field =
      cond do
        refundable? and refund_method == "cash" -> :refunded_cents
        refundable? and refund_method == "hotel_credit" -> :converted_to_credit_cents
        true -> :retained_cents
      end

    allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.each(fn {payment_operation_id, rows} ->
      if is_binary(payment_operation_id) do
        amount = Enum.reduce(rows, 0, &(&1.amount_cents + &2))
        payment = Repo.get!(CashPayment, payment_operation_id)
        update_record!(payment, %{field => Map.get(payment, field, 0) + amount})
        record_cash_payment_settlement!(payment_operation_id, group.group_id, field, amount)
      end
    end)

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents}
  end

  defp settle_credit_for_rooms(allocations, occurred_on, refundable?) do
    Enum.each(allocations, fn allocation ->
      if refundable?,
        do: restore_credit_allocation(allocation, occurred_on),
        else: delete_record!(allocation)
    end)
  end

  defp apply_hotel_credit(operation) do
    apply_to_existing_group(operation, fn group ->
      if group.status != @active_status do
        rejected(operation, "group_not_active")
      else
        with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
             {:ok, amount_cents} <- payment_amount(operation),
             outstanding_deposit_cents <- outstanding_deposit(group),
             :ok <- payment_fits(amount_cents, outstanding_deposit_cents),
             {:ok, allocations} <- credit_allocations(group.guest_id, amount_cents, occurred_on) do
          ensure_group_accounting(group)
          apply_credit_funding(group, operation_id_value(operation), allocations)
          {:ok, updated_group} = refresh_group(group, revision: group.revision + 1)

          {:applied,
           %{
             "operation_id" => operation_id_value(operation),
             "status" => "applied",
             "group_id" => updated_group.group_id,
             "amount_cents" => amount_cents,
             "outstanding_deposit_cents" => outstanding_deposit(updated_group),
             "revision" => updated_group.revision
           }}
        else
          {:error, code} -> rejected(operation, code)
          :payment_exceeds_outstanding -> rejected(operation, "payment_exceeds_outstanding")
        end
      end
    end)
  end

  defp apply_deposit_transfer(operation) do
    with {:ok, _operation_id} <- operation_id(operation),
         {:ok, source_group_id} <- required_identifier(operation, "source_group_id") do
      case Repo.get(Group, source_group_id) do
        nil ->
          rejected(operation, "group_not_found", %{"group_id" => source_group_id})

        source_group ->
          case required_identifier(operation, "destination_group_id") do
            {:error, code} ->
              rejected(operation, code)

            {:ok, destination_group_id} ->
              case Repo.get(Group, destination_group_id) do
                nil ->
                  rejected(operation, "group_not_found", %{"group_id" => destination_group_id})

                destination_group ->
                  apply_deposit_transfer_to_groups(
                    operation,
                    source_group,
                    destination_group
                  )
              end
          end
      end
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_deposit_transfer_to_groups(operation, source_group, destination_group) do
    case stale_revision(operation, source_group) do
      {:stale, expected_revision} ->
        rejected(operation, "stale_revision", stale_details(source_group, expected_revision))

      :ok ->
        case stale_revision_for(operation, "destination_expected_revision", destination_group) do
          {:stale, expected_revision} ->
            rejected(
              operation,
              "stale_revision",
              stale_details(destination_group, expected_revision)
            )

          :ok ->
            cond do
              source_group.group_id == destination_group.group_id or
                  source_group.guest_id != destination_group.guest_id ->
                rejected(operation, "invalid_transfer")

              source_group.status != @active_status ->
                rejected(operation, "group_not_active", %{"group_id" => source_group.group_id})

              destination_group.status != @active_status ->
                rejected(operation, "group_not_active", %{
                  "group_id" => destination_group.group_id
                })

              true ->
                with {:ok, amount_cents} <- payment_amount(operation) do
                  held_cents = cash_paid(source_group) + credit_paid(source_group)
                  destination_outstanding = outstanding_deposit(destination_group)

                  cond do
                    amount_cents > held_cents ->
                      rejected(operation, "transfer_exceeds_held_funding")

                    amount_cents > destination_outstanding ->
                      rejected(operation, "transfer_exceeds_outstanding")

                    true ->
                      ensure_group_accounting(source_group)
                      ensure_group_accounting(destination_group)

                      source_group = Repo.get!(Group, source_group.group_id)
                      destination_group = Repo.get!(Group, destination_group.group_id)
                      source_allocations = transfer_source_allocations(source_group)

                      moved_units =
                        move_transfer_source_allocations(source_allocations, amount_cents)

                      allocate_transfer_units(destination_group, moved_units)

                      {:ok, updated_source} =
                        refresh_group(source_group, revision: source_group.revision + 1)

                      {:ok, updated_destination} =
                        refresh_group(
                          destination_group,
                          revision: destination_group.revision + 1
                        )

                      {:applied,
                       %{
                         "operation_id" => operation_id_value(operation),
                         "status" => "applied",
                         "source_group_id" => updated_source.group_id,
                         "destination_group_id" => updated_destination.group_id,
                         "amount_cents" => amount_cents,
                         "source_outstanding_deposit_cents" =>
                           outstanding_deposit(updated_source),
                         "destination_outstanding_deposit_cents" =>
                           outstanding_deposit(updated_destination),
                         "source_revision" => updated_source.revision,
                         "destination_revision" => updated_destination.revision
                       }}
                  end
                else
                  {:error, code} -> rejected(operation, code)
                end
            end
        end
    end
  end

  defp apply_reduce_cash_payment(operation) do
    case required_identifier(operation, "payment_operation_id") do
      {:error, code} ->
        rejected(operation, code)

      {:ok, target_operation_id} ->
        case cash_payment_target(target_operation_id) do
          {:error, code} ->
            rejected(operation, code)

          {:ok, target_operation, group_id, _recorded_cents} ->
            case Repo.get(Group, group_id) do
              nil ->
                rejected(operation, "group_not_found")

              group ->
                case stale_revision(operation, group) do
                  {:stale, expected_revision} ->
                    rejected(operation, "stale_revision", stale_details(group, expected_revision))

                  :ok ->
                    cond do
                      match?({:error, _}, payment_amount(operation)) ->
                        {:error, code} = payment_amount(operation)
                        rejected(operation, code)

                      true ->
                        {:ok, amount_cents} = payment_amount(operation)
                        ensure_group_accounting(group)
                        payment = ensure_cash_payment(target_operation, group)
                        held_cents = held_cents_for_payment(payment.payment_operation_id)

                        cond do
                          held_cents <= 0 ->
                            rejected(operation, "payment_not_reducible")

                          amount_cents > held_cents ->
                            rejected(operation, "reduction_exceeds_held_cash")

                          true ->
                            affected_group_ids =
                              remove_cash_for_payment(payment.payment_operation_id, amount_cents)

                            update_record!(payment, %{
                              reduced_cents: payment.reduced_cents + amount_cents
                            })

                            updated_group =
                              refresh_groups_with_revision(
                                MapSet.put(affected_group_ids, group.group_id),
                                group.group_id,
                                cash_reduced_cents: (group.cash_reduced_cents || 0) + amount_cents
                              )

                            {:applied,
                             %{
                               "operation_id" => operation_id_value(operation),
                               "status" => "applied",
                               "payment_operation_id" => payment.payment_operation_id,
                               "group_id" => updated_group.group_id,
                               "amount_cents" => amount_cents,
                               "outstanding_deposit_cents" => outstanding_deposit(updated_group),
                               "revision" => updated_group.revision
                             }}
                        end
                    end
                end
            end
        end
    end
  end

  defp apply_charge_back_payment(operation) do
    case required_identifier(operation, "payment_operation_id") do
      {:error, code} ->
        rejected(operation, code)

      {:ok, target_operation_id} ->
        case cash_payment_target(target_operation_id) do
          {:error, "operation_not_found"} ->
            rejected(operation, "operation_not_found")

          {:error, _code} ->
            rejected(operation, "payment_not_chargeable")

          {:ok, target_operation, group_id, _recorded_cents} ->
            case Repo.get(Group, group_id) do
              nil ->
                rejected(operation, "group_not_found")

              group ->
                case stale_revision(operation, group) do
                  {:stale, expected_revision} ->
                    rejected(operation, "stale_revision", stale_details(group, expected_revision))

                  :ok ->
                    ensure_group_accounting(group)
                    payment = ensure_cash_payment(target_operation, group)

                    cond do
                      payment.charged_back ->
                        rejected(operation, "payment_not_chargeable")

                      payment.reduced_cents >= payment.recorded_cents ->
                        rejected(operation, "payment_not_chargeable")

                      true ->
                        held_cents = held_cents_for_payment(payment.payment_operation_id)

                        charged_back_cents =
                          held_cents + payment.refunded_cents + payment.retained_cents +
                            payment.converted_to_credit_cents

                        affected_group_ids =
                          remove_cash_for_payment(payment.payment_operation_id, held_cents)

                        settlement_adjustments =
                          reverse_payment_settlements(payment.payment_operation_id)

                        if payment.converted_to_credit_cents > 0 do
                          revoke_credit_entitlement(payment.payment_operation_id)
                        end

                        update_record!(payment, %{
                          refunded_cents: 0,
                          retained_cents: 0,
                          converted_to_credit_cents: 0,
                          charged_back_cents: payment.charged_back_cents + charged_back_cents,
                          charged_back: true
                        })

                        apply_settlement_adjustments(settlement_adjustments, group, payment)

                        updated_group =
                          refresh_groups_with_revision(
                            MapSet.put(affected_group_ids, group.group_id),
                            group.group_id,
                            cash_charged_back_cents:
                              (group.cash_charged_back_cents || 0) + charged_back_cents
                          )

                        {:applied,
                         %{
                           "operation_id" => operation_id_value(operation),
                           "status" => "applied",
                           "payment_operation_id" => payment.payment_operation_id,
                           "group_id" => updated_group.group_id,
                           "charged_back_cents" => charged_back_cents,
                           "outstanding_deposit_cents" => outstanding_deposit(updated_group),
                           "revision" => updated_group.revision
                         }}
                    end
                end
            end
        end
    end
  end

  defp apply_to_existing_group(operation, callback) do
    with {:ok, _operation_id} <- operation_id(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id") do
      case Repo.get(Group, group_id) do
        nil ->
          rejected(operation, "group_not_found")

        group ->
          case stale_revision(operation, group) do
            :ok ->
              callback.(group)

            {:stale, expected_revision} ->
              rejected(operation, "stale_revision", stale_details(group, expected_revision))
          end
      end
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp stale_details(group, expected_revision),
    do: %{
      "group_id" => group.group_id,
      "expected_revision" => expected_revision,
      "actual_revision" => group.revision
    }

  defp update_group(group, attributes), do: update_record(group, attributes)

  defp refresh_groups_with_revision(group_ids, addressed_group_id, addressed_options) do
    Enum.reduce(MapSet.to_list(group_ids), nil, fn group_id, updated_addressed_group ->
      group = Repo.get!(Group, group_id)

      options =
        if group_id == addressed_group_id,
          do: Keyword.put(addressed_options, :revision, group.revision + 1),
          else: [revision: group.revision + 1]

      {:ok, updated_group} = refresh_group(group, options)

      if group_id == addressed_group_id, do: updated_group, else: updated_addressed_group
    end)
  end

  defp refresh_group(group, options) do
    group = Repo.get!(Group, group.group_id)
    rooms = normalize_rooms(group)
    balances = room_balances(group)
    active_rooms = Enum.filter(rooms, &(&1["status"] == @active_status))

    totals = %{
      lodging_total_cents: Enum.reduce(active_rooms, 0, &(&1["lodging_total_cents"] + &2)),
      deposit_due_cents: Enum.reduce(active_rooms, 0, &(&1["deposit_due_cents"] + &2)),
      deposit_paid_cents:
        Enum.reduce(active_rooms, 0, fn room, total ->
          {cash, credit} = Map.get(balances, room["room_id"], {0, 0})
          total + cash + credit
        end),
      cash_paid_cents:
        Enum.reduce(active_rooms, 0, fn room, total ->
          {cash, _credit} = Map.get(balances, room["room_id"], {0, 0})
          total + cash
        end),
      credit_paid_cents:
        Enum.reduce(active_rooms, 0, fn room, total ->
          {_cash, credit} = Map.get(balances, room["room_id"], {0, 0})
          total + credit
        end),
      rooms_json: Jason.encode!(rooms)
    }

    attributes =
      totals
      |> Map.merge(Map.new(options))
      |> Map.put_new(:status, if(active_rooms == [], do: @cancelled_status, else: @active_status))

    update_record(group, attributes)
  end

  defp update_record(record, attributes) do
    case Repo.update(change(record, attributes)) do
      {:ok, updated_record} -> {:ok, updated_record}
      {:error, changeset} -> Repo.rollback({:record_update_failed, changeset})
    end
  end

  defp update_record!(record, attributes) do
    {:ok, updated_record} = update_record(record, attributes)
    updated_record
  end

  defp delete_record!(record) do
    case Repo.delete(record) do
      {:ok, deleted} -> deleted
      {:error, changeset} -> Repo.rollback({:record_delete_failed, changeset})
    end
  end

  defp ensure_group_accounting(group) do
    if group.status == @active_status do
      payments = ensure_cash_accounting(group)
      credit_sources = ensure_credit_accounting(group)
      allocate_durable_funding(group, payments, credit_sources)
    end
  end

  defp ensure_cash_accounting(group) do
    if group.status == @active_status do
      payments = durable_cash_payments(group.group_id)
      allocations = cash_allocations(group.group_id)

      if allocations == [] do
        target_cash = cash_paid(group)
        durable_total = Enum.reduce(payments, 0, &(&1.recorded_cents + &2))
        legacy_cash = max(target_cash - durable_total, 0)
        allocate_cash_funding(group, nil, legacy_cash)
      else
        missing = max(cash_paid(group) - Enum.reduce(allocations, 0, &(&1.amount_cents + &2)), 0)
        if missing > 0, do: allocate_cash_funding(group, nil, missing)
      end

      payments
    end
  end

  defp ensure_credit_accounting(group) do
    if group.status == @active_status do
      legacy_allocations =
        Repo.all(
          from allocation in CreditAllocation,
            where: allocation.group_id == ^group.group_id and is_nil(allocation.room_id),
            order_by: [asc: allocation.id]
        )

      if legacy_allocations == [] do
        %{}
      else
        durable_operations = durable_credit_operations(group.group_id)

        durable_total =
          Enum.reduce(durable_operations, 0, fn {_operation, result}, total ->
            total + result["amount_cents"]
          end)

        legacy_amount = max(credit_paid(group) - durable_total, 0)
        Enum.each(legacy_allocations, &delete_record!/1)

        {legacy_lots, remaining_rows} = take_credit_rows(legacy_allocations, legacy_amount)
        insert_credit_source_allocations(group, nil, legacy_lots)

        Enum.reduce(durable_operations, {remaining_rows, %{}}, fn {operation, result},
                                                                  {rows, sources} ->
          {lots, remaining} = take_credit_rows(rows, result["amount_cents"])
          {remaining, Map.put(sources, operation.operation_id, lots)}
        end)
        |> elem(1)
      end
    else
      %{}
    end
  end

  defp durable_credit_operations(group_id) do
    durable_funding_operations(group_id)
    |> Enum.filter(fn {operation, _result} -> operation.type == "apply_hotel_credit" end)
  end

  defp durable_funding_operations(group_id) do
    Repo.all(from operation in Operation, order_by: [asc: operation.commit_order])
    |> Enum.flat_map(fn operation ->
      with true <- operation.type in ["record_cash_payment", "apply_hotel_credit"],
           {:ok, result} <- Jason.decode(operation.result_json),
           true <- result["status"] == "applied" and result["group_id"] == group_id do
        [{operation, result}]
      else
        _ -> []
      end
    end)
  end

  defp take_credit_rows(rows, amount_cents) do
    {taken, remaining, _amount_left} =
      Enum.reduce(rows, {[], [], amount_cents}, fn row, {taken, remaining, amount_left} ->
        take = min(max(amount_left, 0), row.amount_cents)
        remainder = row.amount_cents - take
        taken = if take > 0, do: taken ++ [{row.credit_lot_id, take}], else: taken

        remaining =
          if remainder > 0, do: remaining ++ [%{row | amount_cents: remainder}], else: remaining

        {taken, remaining, amount_left - take}
      end)

    {taken, remaining}
  end

  defp insert_credit_source_allocations(_group, _funding_operation_id, []), do: :ok

  defp insert_credit_source_allocations(group, funding_operation_id, lot_allocations) do
    Enum.each(lot_allocations, fn {credit_lot_id, amount_cents} ->
      Enum.each(room_chunks(group, amount_cents), fn {_room_index, room_id, amount} ->
        insert_credit_allocation!(%CreditAllocation{
          group_id: group.group_id,
          room_id: room_id,
          credit_lot_id: credit_lot_id,
          amount_cents: amount,
          funding_operation_id: funding_operation_id
        })
      end)
    end)
  end

  defp allocate_durable_funding(group, _payments, credit_sources) do
    Enum.each(durable_funding_operations(group.group_id), fn {operation, result} ->
      case operation.type do
        "record_cash_payment" ->
          if cash_allocations_for_payment(operation.operation_id) == [] do
            payment = Repo.get(CashPayment, operation.operation_id)

            unless payment && payment.transferred do
              allocate_cash_funding(group, operation.operation_id, result["amount_cents"])
            end
          end

        "apply_hotel_credit" ->
          insert_credit_source_allocations(
            group,
            operation.operation_id,
            Map.get(credit_sources, operation.operation_id, [])
          )
      end
    end)
  end

  defp cash_allocations_for_payment(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id
    )
  end

  defp durable_cash_payments(group_id) do
    Repo.all(from operation in Operation, order_by: [asc: operation.commit_order])
    |> Enum.filter(fn operation ->
      operation.type == "record_cash_payment" and
        case Jason.decode(operation.result_json) do
          {:ok, %{"status" => "applied", "group_id" => ^group_id}} -> true
          _ -> false
        end
    end)
    |> Enum.map(&ensure_cash_payment(&1, Repo.get!(Group, group_id)))
  end

  defp ensure_cash_payment(operation, group) do
    case Repo.get(CashPayment, operation.operation_id) do
      %CashPayment{} = payment ->
        payment

      nil ->
        result = Jason.decode!(operation.result_json)
        legacy = legacy_payment_state(operation, result)

        insert_cash_payment!(%CashPayment{
          payment_operation_id: operation.operation_id,
          group_id: group.group_id,
          recorded_cents: result["amount_cents"],
          refunded_cents: legacy.refunded_cents,
          retained_cents: legacy.retained_cents,
          converted_to_credit_cents: legacy.converted_to_credit_cents,
          reduced_cents: legacy.reduced_cents,
          charged_back_cents: legacy.charged_back_cents,
          charged_back: false,
          transferred: false
        })
    end
  end

  defp insert_cash_payment(operation_id, group, amount_cents) do
    case Repo.insert(%CashPayment{
           payment_operation_id: operation_id,
           group_id: group.group_id,
           recorded_cents: amount_cents,
           refunded_cents: 0,
           retained_cents: 0,
           converted_to_credit_cents: 0,
           reduced_cents: 0,
           charged_back_cents: 0,
           charged_back: false,
           transferred: false
         }) do
      {:ok, payment} -> {:ok, payment}
      {:error, changeset} -> Repo.rollback({:cash_payment_insert_failed, changeset})
    end
  end

  defp insert_cash_payment!(payment) do
    case Repo.insert(payment) do
      {:ok, inserted} -> inserted
      {:error, changeset} -> Repo.rollback({:cash_payment_insert_failed, changeset})
    end
  end

  defp record_cash_payment_settlement!(payment_operation_id, group_id, field, amount_cents) do
    settlement =
      Repo.get_by(CashPaymentSettlement,
        payment_operation_id: payment_operation_id,
        group_id: group_id
      )

    if settlement do
      update_record!(settlement, %{field => Map.get(settlement, field, 0) + amount_cents})
    else
      attributes = %{
        payment_operation_id: payment_operation_id,
        group_id: group_id,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0
      }

      {:ok, _settlement} =
        Repo.insert(struct(CashPaymentSettlement, Map.put(attributes, field, amount_cents)))
    end
  end

  defp reverse_payment_settlements(payment_operation_id) do
    Repo.all(
      from settlement in CashPaymentSettlement,
        where: settlement.payment_operation_id == ^payment_operation_id
    )
    |> Enum.reduce(%{}, fn settlement, adjustments ->
      adjustment = %{
        refunded_cents: settlement.refunded_cents || 0,
        retained_cents: settlement.retained_cents || 0,
        converted_to_credit_cents: settlement.converted_to_credit_cents || 0
      }

      update_record!(settlement, %{
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0
      })

      Map.put(adjustments, settlement.group_id, adjustment)
    end)
  end

  defp apply_settlement_adjustments(adjustments, group, payment) do
    adjustments =
      if map_size(adjustments) == 0 do
        adjustment = %{
          refunded_cents: payment.refunded_cents || 0,
          retained_cents: payment.retained_cents || 0,
          converted_to_credit_cents: payment.converted_to_credit_cents || 0
        }

        if Enum.any?(Map.values(adjustment), &(&1 > 0)),
          do: %{group.group_id => adjustment},
          else: %{}
      else
        adjustments
      end

    Enum.each(adjustments, fn {group_id, adjustment} ->
      settled_group = Repo.get!(Group, group_id)

      update_record!(settled_group, %{
        refunded_cents: max((settled_group.refunded_cents || 0) - adjustment.refunded_cents, 0),
        retained_cents: max((settled_group.retained_cents || 0) - adjustment.retained_cents, 0),
        cash_converted_to_credit_cents:
          max(
            (settled_group.cash_converted_to_credit_cents || 0) -
              adjustment.converted_to_credit_cents,
            0
          )
      })
    end)
  end

  defp mark_cash_payment_transferred(payment_operation_id) do
    case Repo.get(CashPayment, payment_operation_id) do
      nil -> :ok
      %CashPayment{transferred: true} -> :ok
      %CashPayment{} = payment -> update_record!(payment, %{transferred: true})
    end
  end

  defp allocate_cash_funding(_group, _payment_operation_id, amount_cents) when amount_cents <= 0,
    do: 0

  defp allocate_cash_funding(group, payment_operation_id, amount_cents) do
    chunks = room_chunks(group, amount_cents)

    Enum.each(chunks, fn {room_index, room_id, amount} ->
      insert_cash_allocation!(%CashAllocation{
        group_id: group.group_id,
        room_id: room_id,
        room_index: room_index,
        payment_operation_id: payment_operation_id,
        amount_cents: amount
      })
    end)

    Enum.reduce(chunks, 0, fn {_index, _room_id, amount}, total -> total + amount end)
  end

  defp apply_credit_funding(group, funding_operation_id, allocations) do
    Enum.each(allocations, fn {lot, amount_cents} ->
      update_credit_lot(lot, lot.remaining_cents - amount_cents)

      Enum.each(room_chunks(group, amount_cents), fn {_room_index, room_id, amount} ->
        insert_credit_allocation!(%CreditAllocation{
          group_id: group.group_id,
          room_id: room_id,
          credit_lot_id: lot.id,
          amount_cents: amount,
          funding_operation_id: funding_operation_id
        })
      end)
    end)
  end

  defp room_chunks(group, amount_cents) do
    rooms = normalize_rooms(group)
    balances = room_balances(group)

    {chunks, _remaining} =
      Enum.reduce(rooms, {[], amount_cents}, fn room, {chunks, remaining} ->
        {cash, credit} = Map.get(balances, room["room_id"], {0, 0})
        capacity = max(room["deposit_due_cents"] - cash - credit, 0)
        amount = min(capacity, remaining)

        if amount > 0,
          do: {chunks ++ [{room["room_index"], room["room_id"], amount}], remaining - amount},
          else: {chunks, remaining}
      end)

    if Enum.reduce(chunks, 0, fn {_index, _room_id, amount}, total -> total + amount end) <
         amount_cents,
       do: Repo.rollback(:room_funding_exceeds_outstanding)

    chunks
  end

  defp transfer_source_allocations(group) do
    active_room_ids = MapSet.new(active_room_ids(group))
    operation_orders = operation_orders()

    cash_allocations =
      cash_allocations(group.group_id)
      |> Enum.filter(&MapSet.member?(active_room_ids, &1.room_id))
      |> Enum.map(fn allocation ->
        %{
          kind: :cash,
          allocation: allocation,
          amount_cents: allocation.amount_cents,
          sort_key: allocation_sort_key(allocation, :cash, operation_orders)
        }
      end)

    credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.group_id,
          order_by: [asc: allocation.id]
      )
      |> Enum.filter(&MapSet.member?(active_room_ids, &1.room_id))
      |> Enum.map(fn allocation ->
        %{
          kind: :credit,
          allocation: allocation,
          amount_cents: allocation.amount_cents,
          sort_key: allocation_sort_key(allocation, :credit, operation_orders)
        }
      end)

    (cash_allocations ++ credit_allocations)
    |> Enum.sort_by(& &1.sort_key, :desc)
  end

  defp allocation_sort_key(allocation, kind, operation_orders) do
    operation_id =
      case kind do
        :cash -> allocation.payment_operation_id
        :credit -> allocation.funding_operation_id
      end

    case allocation.allocation_order do
      order when is_integer(order) ->
        {2, order, 0, ""}

      _ ->
        if is_binary(operation_id),
          do: {1, Map.get(operation_orders, operation_id, 0), allocation.id, ""},
          else: {0, 0, allocation.id, ""}
    end
  end

  defp move_transfer_source_allocations(allocations, amount_cents) do
    {moved_units, remaining} =
      Enum.reduce_while(allocations, {[], amount_cents}, fn entry, {moved, remaining} ->
        take = min(remaining, entry.amount_cents)

        if take <= 0 do
          {:halt, {moved, remaining}}
        else
          allocation = entry.allocation

          if take == allocation.amount_cents,
            do: delete_record!(allocation),
            else: update_record!(allocation, %{amount_cents: allocation.amount_cents - take})

          if entry.kind == :cash and is_binary(allocation.payment_operation_id),
            do: mark_cash_payment_transferred(allocation.payment_operation_id)

          moved = moved ++ [%{entry | amount_cents: take}]
          remaining = remaining - take

          if remaining == 0,
            do: {:halt, {moved, remaining}},
            else: {:cont, {moved, remaining}}
        end
      end)

    if remaining > 0, do: Repo.rollback(:transfer_source_shortfall)
    moved_units
  end

  defp allocate_transfer_units(group, moved_units) do
    rooms =
      normalize_rooms(group)
      |> Enum.filter(&(&1["status"] == @active_status))
      |> Enum.map(fn room ->
        {cash, credit} = Map.get(room_balances(group), room["room_id"], {0, 0})

        %{
          room_index: room["room_index"],
          room_id: room["room_id"],
          capacity: max(room["deposit_due_cents"] - cash - credit, 0)
        }
      end)

    {chunks, remaining_rooms} =
      Enum.reduce(moved_units, {[], rooms}, fn unit, {chunks, rooms} ->
        {unit_chunks, rooms} = allocate_transfer_unit(unit, rooms, [])
        {chunks ++ unit_chunks, rooms}
      end)

    if Enum.any?(remaining_rooms, &(&1.capacity < 0)),
      do: Repo.rollback(:transfer_destination_shortfall)

    Enum.each(chunks, fn {unit, room_index, room_id, amount_cents} ->
      allocation = unit.allocation

      case unit.kind do
        :cash ->
          insert_cash_allocation!(%CashAllocation{
            group_id: group.group_id,
            room_id: room_id,
            room_index: room_index,
            payment_operation_id: allocation.payment_operation_id,
            amount_cents: amount_cents
          })

        :credit ->
          insert_credit_allocation!(%CreditAllocation{
            group_id: group.group_id,
            room_id: room_id,
            credit_lot_id: allocation.credit_lot_id,
            amount_cents: amount_cents,
            funding_operation_id: allocation.funding_operation_id
          })
      end
    end)
  end

  defp allocate_transfer_unit(unit, rooms, chunks) do
    case {unit.amount_cents, rooms} do
      {0, rooms} ->
        {chunks, rooms}

      {_amount, []} ->
        Repo.rollback(:transfer_destination_shortfall)

      {_amount, [room | remaining_rooms]} when room.capacity == 0 ->
        allocate_transfer_unit(unit, remaining_rooms, chunks)

      {amount, [room | remaining_rooms]} ->
        take = min(amount, room.capacity)
        chunk = {unit, room.room_index, room.room_id, take}
        updated_room = %{room | capacity: room.capacity - take}
        chunks = chunks ++ [chunk]

        if take == amount do
          {chunks, [updated_room | remaining_rooms]}
        else
          allocate_transfer_unit(
            %{unit | amount_cents: amount - take},
            remaining_rooms,
            chunks
          )
        end
    end
  end

  defp put_new_allocation_order(%{allocation_order: order} = allocation)
       when is_integer(order),
       do: allocation

  defp put_new_allocation_order(allocation),
    do: %{allocation | allocation_order: next_allocation_order()}

  defp next_allocation_order do
    cash_max =
      Repo.one(from allocation in CashAllocation, select: max(allocation.allocation_order))

    credit_max =
      Repo.one(from allocation in CreditAllocation, select: max(allocation.allocation_order))

    max(cash_max || 0, credit_max || 0) + 1
  end

  defp insert_cash_allocation!(allocation) do
    allocation = put_new_allocation_order(allocation)

    case Repo.insert(allocation) do
      {:ok, inserted} -> inserted
      {:error, changeset} -> Repo.rollback({:cash_allocation_insert_failed, changeset})
    end
  end

  defp insert_credit_allocation!(allocation) do
    allocation = put_new_allocation_order(allocation)

    case Repo.insert(allocation) do
      {:ok, inserted} -> inserted
      {:error, changeset} -> Repo.rollback({:credit_allocation_insert_failed, changeset})
    end
  end

  defp room_balances(group) do
    cash =
      Repo.all(from allocation in CashAllocation, where: allocation.group_id == ^group.group_id)
      |> Enum.reduce(%{}, fn allocation, balances ->
        if is_binary(allocation.room_id),
          do:
            Map.update(balances, allocation.room_id, {allocation.amount_cents, 0}, fn {cash,
                                                                                       credit} ->
              {cash + allocation.amount_cents, credit}
            end),
          else: balances
      end)

    Repo.all(from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id)
    |> Enum.reduce(cash, fn allocation, balances ->
      if is_binary(allocation.room_id),
        do:
          Map.update(balances, allocation.room_id, {0, allocation.amount_cents}, fn {cash, credit} ->
            {cash, credit + allocation.amount_cents}
          end),
        else: balances
    end)
  end

  defp cash_allocations(group_id),
    do:
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.group_id == ^group_id,
          order_by: [asc: allocation.id]
      )

  defp cash_allocations_for_rooms(group_id, room_ids) do
    wanted = MapSet.new(room_ids)
    Enum.filter(cash_allocations(group_id), &MapSet.member?(wanted, &1.room_id))
  end

  defp credit_allocations_for_rooms(group_id, room_ids) do
    wanted = MapSet.new(room_ids)

    Repo.all(
      from allocation in CreditAllocation,
        where: allocation.group_id == ^group_id,
        order_by: [asc: allocation.id]
    )
    |> Enum.filter(&MapSet.member?(wanted, &1.room_id))
  end

  defp delete_cash_allocations(allocations), do: Enum.each(allocations, &delete_record!/1)

  defp remove_cash_for_payment(payment_operation_id, amount_cents) do
    if amount_cents <= 0 do
      MapSet.new()
    else
      operation_orders = operation_orders()

      allocations =
        Repo.all(
          from allocation in CashAllocation,
            where: allocation.payment_operation_id == ^payment_operation_id
        )
        |> Enum.sort_by(&allocation_sort_key(&1, :cash, operation_orders), :desc)

      {remaining, affected_group_ids} =
        Enum.reduce_while(allocations, {amount_cents, MapSet.new()}, fn allocation,
                                                                        {remaining, group_ids} ->
          take = min(remaining, allocation.amount_cents)
          group_ids = MapSet.put(group_ids, allocation.group_id)

          if take == allocation.amount_cents do
            delete_record!(allocation)

            if remaining - take == 0,
              do: {:halt, {0, group_ids}},
              else: {:cont, {remaining - take, group_ids}}
          else
            update_record!(allocation, %{amount_cents: allocation.amount_cents - take})
            {:halt, {0, group_ids}}
          end
        end)

      if remaining > 0, do: Repo.rollback(:cash_reduction_allocation_shortfall)
      affected_group_ids
    end
  end

  defp held_cents_for_payment(payment_operation_id),
    do:
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.payment_operation_id == ^payment_operation_id
      )
      |> Enum.reduce(0, &(&1.amount_cents + &2))

  defp issue_credit_lot(guest_id, source_operation_id, amount_cents, issued_on) do
    case Repo.insert(%CreditLot{
           guest_id: guest_id,
           source_operation_id: source_operation_id,
           remaining_cents: amount_cents,
           issued_on: issued_on,
           expires_on: Date.add(issued_on, 365),
           unrecovered_clawback_cents: 0
         }) do
      {:ok, lot} -> lot
      {:error, changeset} -> Repo.rollback({:credit_lot_insert_failed, changeset})
    end
  end

  defp add_credit_lot_contributions(lot, sources, cash_cents) do
    sources = Enum.filter(sources, fn {_payment_id, amount} -> amount > 0 end)
    sources = if sources == [] and cash_cents > 0, do: [{nil, cash_cents}], else: sources

    Enum.reduce(sources, {0, 0}, fn {payment_operation_id, amount}, {cash_so_far, value_so_far} ->
      new_cash = cash_so_far + amount
      new_value = new_cash + round_percentage(new_cash, 10, 100)
      entitlement = new_value - value_so_far

      insert_credit_contribution!(%CreditLotContribution{
        credit_lot_id: lot.id,
        payment_operation_id: payment_operation_id,
        entitlement_cents: entitlement,
        clawed_back_cents: 0
      })

      {new_cash, new_value}
    end)
  end

  defp insert_credit_contribution!(contribution) do
    case Repo.insert(contribution) do
      {:ok, inserted} -> inserted
      {:error, changeset} -> Repo.rollback({:credit_contribution_insert_failed, changeset})
    end
  end

  defp ordered_cash_sources(allocations) do
    orders = operation_orders()

    allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.map(fn {payment_operation_id, rows} ->
      {payment_operation_id, Enum.reduce(rows, 0, &(&1.amount_cents + &2))}
    end)
    |> Enum.sort_by(fn {payment_operation_id, _amount} ->
      if is_nil(payment_operation_id),
        do: {0, 0, ""},
        else: {1, Map.get(orders, payment_operation_id, 0), payment_operation_id}
    end)
  end

  defp operation_orders do
    Repo.all(
      from operation in Operation, select: {operation.operation_id, operation.commit_order}
    )
    |> Map.new()
  end

  defp restore_credit_allocation(allocation, occurred_on) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    unrecovered = lot.unrecovered_clawback_cents || 0
    absorbed = min(unrecovered, allocation.amount_cents)
    extra = allocation.amount_cents - absorbed

    remaining =
      if extra > 0 and Date.compare(lot.expires_on, occurred_on) in [:eq, :gt],
        do: lot.remaining_cents + extra,
        else: lot.remaining_cents

    update_credit_lot_record!(lot, %{
      remaining_cents: remaining,
      unrecovered_clawback_cents: unrecovered - absorbed
    })

    delete_record!(allocation)
  end

  defp revoke_credit_entitlement(payment_operation_id) do
    ensure_credit_contributions(payment_operation_id)

    Repo.all(
      from contribution in CreditLotContribution,
        where: contribution.payment_operation_id == ^payment_operation_id,
        order_by: [asc: contribution.id]
    )
    |> Enum.each(fn contribution ->
      remaining_entitlement = contribution.entitlement_cents - contribution.clawed_back_cents

      if remaining_entitlement > 0 do
        lot = Repo.get!(CreditLot, contribution.credit_lot_id)
        remove = min(lot.remaining_cents, remaining_entitlement)

        update_credit_lot_record!(lot, %{
          remaining_cents: lot.remaining_cents - remove,
          unrecovered_clawback_cents:
            (lot.unrecovered_clawback_cents || 0) + remaining_entitlement - remove
        })

        update_record!(contribution, %{clawed_back_cents: contribution.entitlement_cents})
      end
    end)
  end

  defp ensure_credit_contributions(payment_operation_id) do
    unless Repo.exists?(
             from contribution in CreditLotContribution,
               where: contribution.payment_operation_id == ^payment_operation_id
           ) do
      Repo.all(from operation in Operation, order_by: [asc: operation.commit_order])
      |> Enum.each(fn operation ->
        if operation.type in ["cancel_group", "cancel_rooms"] do
          result = Jason.decode!(operation.result_json)

          if result["status"] == "applied" do
            payload = Jason.decode!(operation.payload_json)
            group = Repo.get(Group, payload["group_id"])

            lot =
              if group,
                do: Repo.get_by(CreditLot, source_operation_id: operation.operation_id),
                else: nil

            if lot && lot_has_no_contributions?(lot),
              do: add_reconstructed_contributions(lot, group, operation.commit_order)
          end
        end
      end)
    end
  end

  defp lot_has_no_contributions?(lot),
    do:
      not Repo.exists?(
        from contribution in CreditLotContribution, where: contribution.credit_lot_id == ^lot.id
      )

  defp add_reconstructed_contributions(lot, group, cancellation_order) do
    principal = group.cash_converted_to_credit_cents || 0

    payments =
      durable_cash_payments(group.group_id)
      |> Enum.filter(fn payment ->
        case Repo.get_by(Operation, operation_id: payment.payment_operation_id) do
          %Operation{commit_order: order} -> order < cancellation_order
          _ -> false
        end
      end)

    durable_total = Enum.reduce(payments, 0, &(&1.recorded_cents + &2))

    sources = [
      {nil, max(principal - durable_total, 0)}
      | Enum.map(payments, &{&1.payment_operation_id, &1.recorded_cents})
    ]

    add_credit_lot_contributions(lot, sources, principal)
  end

  defp update_credit_lot(lot, remaining_cents),
    do: update_credit_lot_record!(lot, %{remaining_cents: remaining_cents})

  defp update_credit_lot_record!(lot, attributes), do: update_record!(lot, attributes)

  defp credit_allocations(guest_id, amount_cents, as_of) do
    lots = available_credit_lots(guest_id, as_of)

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) < amount_cents,
      do: {:error, "insufficient_credit"},
      else: {:ok, take_credit_from_lots(lots, amount_cents)}
  end

  defp take_credit_from_lots(lots, amount_cents) do
    {_, allocations} =
      Enum.reduce_while(lots, {amount_cents, []}, fn lot, {remaining, allocations} ->
        amount = min(remaining, lot.remaining_cents)

        if amount == remaining,
          do: {:halt, {0, allocations ++ [{lot, amount}]}},
          else: {:cont, {remaining - amount, allocations ++ [{lot, amount}]}}
      end)

    allocations
  end

  defp available_credit_lots(guest_id, as_of) do
    Repo.all(from lot in CreditLot, where: lot.guest_id == ^guest_id)
    |> Enum.filter(fn lot ->
      lot.remaining_cents > 0 and Date.compare(credit_issued_on(lot), as_of) in [:lt, :eq] and
        Date.compare(lot.expires_on, as_of) in [:eq, :gt]
    end)
    |> Enum.sort_by(fn lot -> {lot.expires_on, lot.source_operation_id, lot.id} end)
  end

  defp credit_issued_on(%CreditLot{issued_on: nil, expires_on: expires_on}),
    do: Date.add(expires_on, -365)

  defp credit_issued_on(%CreditLot{issued_on: issued_on}), do: issued_on

  defp current_credit_shortfall do
    active_ids =
      Repo.all(
        from group in Group, where: group.status == ^@active_status, select: group.group_id
      )
      |> MapSet.new()

    active_by_lot =
      Repo.all(CreditAllocation)
      |> Enum.filter(&MapSet.member?(active_ids, &1.group_id))
      |> Enum.reduce(%{}, fn allocation, totals ->
        Map.update(
          totals,
          allocation.credit_lot_id,
          allocation.amount_cents,
          &(&1 + allocation.amount_cents)
        )
      end)

    Repo.all(CreditLot)
    |> Enum.reduce(0, fn lot, total ->
      total + min(lot.unrecovered_clawback_cents || 0, Map.get(active_by_lot, lot.id, 0))
    end)
  end

  defp stale_revision(operation, group) do
    stale_revision_for(operation, "expected_revision", group)
  end

  defp stale_revision_for(operation, key, group) do
    if Map.has_key?(operation, key) do
      expected_revision = Map.get(operation, key)
      if expected_revision === group.revision, do: :ok, else: {:stale, expected_revision}
    else
      :ok
    end
  end

  defp calculate_rooms(operation, arrival_on, departure_on, rate_plan) do
    rooms = Map.get(operation, "rooms")
    nights = Date.diff(departure_on, arrival_on)

    if is_list(rooms) and rooms != [] do
      rooms
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], 0, 0, MapSet.new()}, fn {room, room_index},
                                                             {:ok, parsed, lodging, deposit, ids} ->
        with {:ok, room_id} <- room_identifier(room),
             :ok <- unique_room_id(room_id, ids),
             {:ok, nightly_rate_cents} <- nightly_rate(room) do
          room_lodging = nights * nightly_rate_cents

          room_deposit =
            if rate_plan == "flexible",
              do: round_percentage(room_lodging, 20, 100),
              else: room_lodging

          room = %{
            "room_id" => room_id,
            "nightly_rate_cents" => nightly_rate_cents,
            "lodging_total_cents" => room_lodging,
            "status" => @active_status,
            "deposit_due_cents" => room_deposit,
            "cash_paid_cents" => 0,
            "credit_paid_cents" => 0,
            "room_index" => room_index
          }

          {:cont,
           {:ok, parsed ++ [room], lodging + room_lodging, deposit + room_deposit,
            MapSet.put(ids, room_id)}}
        else
          _ -> {:halt, :invalid_rooms}
        end
      end)
      |> case do
        {:ok, parsed, lodging, deposit, _ids} -> {:ok, parsed, lodging, deposit}
        :invalid_rooms -> {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp normalize_rooms(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Jason.decode!(group.rooms_json)
    |> Enum.with_index()
    |> Enum.map(fn {room, room_index} ->
      nightly_rate_cents = Map.get(room, "nightly_rate_cents")
      lodging = Map.get(room, "lodging_total_cents", nights * nightly_rate_cents)

      default_deposit =
        if group.rate_plan == "flexible", do: round_percentage(lodging, 20, 100), else: lodging

      deposit = Map.get(room, "deposit_due_cents", default_deposit)

      status =
        Map.get(
          room,
          "status",
          if(group.status == @cancelled_status, do: @cancelled_status, else: @active_status)
        )

      Map.merge(room, %{
        "room_index" => room_index,
        "lodging_total_cents" => lodging,
        "status" => status,
        "deposit_due_cents" => deposit,
        "cash_paid_cents" => Map.get(room, "cash_paid_cents", 0),
        "credit_paid_cents" => Map.get(room, "credit_paid_cents", 0)
      })
    end)
  end

  defp room_balances_for_public(group) do
    rooms = normalize_rooms(group)
    balances = room_balances(group)

    room_cash_total =
      Enum.reduce(balances, 0, fn {_room_id, {cash, _credit}}, total -> total + cash end)

    legacy_cash_rows = cash_allocations(group.group_id) |> Enum.filter(&is_nil(&1.room_id))

    legacy_cash =
      Enum.reduce(legacy_cash_rows, 0, &(&1.amount_cents + &2)) +
        max(
          cash_paid(group) - room_cash_total -
            Enum.reduce(cash_allocations(group.group_id), 0, &(&1.amount_cents + &2)),
          0
        )

    credit_rows =
      Repo.all(from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id)

    legacy_credit_rows = Enum.filter(credit_rows, &is_nil(&1.room_id))
    credit_total = Enum.reduce(credit_rows, 0, &(&1.amount_cents + &2))

    legacy_credit =
      Enum.reduce(legacy_credit_rows, 0, &(&1.amount_cents + &2)) +
        max(credit_paid(group) - credit_total, 0)

    cond do
      group.status != @active_status ->
        balances

      cash_allocations(group.group_id) == [] and Enum.all?(credit_rows, &is_nil(&1.room_id)) ->
        durable_operations = durable_funding_operations(group.group_id)

        durable_cash =
          Enum.reduce(durable_operations, 0, fn {operation, result}, total ->
            if operation.type == "record_cash_payment",
              do: total + result["amount_cents"],
              else: total
          end)

        durable_credit =
          Enum.reduce(durable_operations, 0, fn {operation, result}, total ->
            if operation.type == "apply_hotel_credit",
              do: total + result["amount_cents"],
              else: total
          end)

        durable_operations
        |> Enum.reduce(
          balances
          |> add_room_funding(rooms, max(cash_paid(group) - durable_cash, 0), :cash)
          |> add_room_funding(rooms, max(credit_paid(group) - durable_credit, 0), :credit),
          fn {operation, result}, funding ->
            add_room_funding(
              funding,
              rooms,
              result["amount_cents"],
              if(operation.type == "record_cash_payment", do: :cash, else: :credit)
            )
          end
        )

      true ->
        balances
        |> add_room_funding(rooms, legacy_cash, :cash)
        |> add_room_funding(rooms, legacy_credit, :credit)
    end
  end

  defp add_room_funding(balances, rooms, amount, kind) do
    {balances, _remaining} =
      Enum.reduce(rooms, {balances, amount}, fn room, {balances, remaining} ->
        {cash, credit} = Map.get(balances, room["room_id"], {0, 0})
        take = min(max(room["deposit_due_cents"] - cash - credit, 0), remaining)
        value = if kind == :cash, do: {cash + take, credit}, else: {cash, credit + take}
        {Map.put(balances, room["room_id"], value), remaining - take}
      end)

    balances
  end

  defp public_group(group) do
    rooms = normalize_rooms(group)
    balances = room_balances_for_public(group)

    rooms =
      Enum.map(rooms, fn room ->
        {cash, credit} = Map.get(balances, room["room_id"], {0, 0})

        room
        |> Map.merge(%{"cash_paid_cents" => cash, "credit_paid_cents" => credit})
        |> Map.delete("room_index")
      end)

    active_rooms = Enum.filter(rooms, &(&1["status"] == @active_status))
    lodging_total = Enum.reduce(active_rooms, 0, &(&1["lodging_total_cents"] + &2))
    deposit_due = Enum.reduce(active_rooms, 0, &(&1["deposit_due_cents"] + &2))

    cash_paid_total =
      Enum.reduce(active_rooms, 0, fn room, total -> total + room["cash_paid_cents"] end)

    credit_paid_total =
      Enum.reduce(active_rooms, 0, fn room, total -> total + room["credit_paid_cents"] end)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => refundable_until_json(group),
      "status" => group.status,
      "rooms" => rooms,
      "lodging_total_cents" => lodging_total,
      "deposit_due_cents" => deposit_due,
      "deposit_paid_cents" => cash_paid_total + credit_paid_total,
      "cash_paid_cents" => cash_paid_total,
      "credit_paid_cents" => credit_paid_total,
      "outstanding_deposit_cents" => max(deposit_due - cash_paid_total - credit_paid_total, 0)
    }
  end

  defp active_room_ids(group),
    do:
      group
      |> normalize_rooms()
      |> Enum.filter(&(&1["status"] == @active_status))
      |> Enum.map(& &1["room_id"])

  defp mark_rooms_cancelled(group, selected_room_ids) do
    selected = MapSet.new(selected_room_ids)

    rooms =
      Enum.map(normalize_rooms(group), fn room ->
        if MapSet.member?(selected, room["room_id"]),
          do: Map.put(room, "status", @cancelled_status),
          else: room
      end)

    update_record!(group, %{rooms_json: Jason.encode!(rooms)})
  end

  defp requested_room_ids(operation, group) do
    room_ids = Map.get(operation, "room_ids")
    active = MapSet.new(active_room_ids(group))

    if is_list(room_ids) and room_ids != [] and
         length(room_ids) == MapSet.size(MapSet.new(room_ids)) and
         Enum.all?(room_ids, &is_binary/1) and Enum.all?(room_ids, &MapSet.member?(active, &1)),
       do: {:ok, order_room_ids(group, room_ids)},
       else: {:error, "invalid_rooms"}
  end

  defp order_room_ids(group, room_ids), do: Enum.sort_by(room_ids, &room_index(group, &1))

  defp room_index(group, room_id),
    do:
      Enum.find_value(
        normalize_rooms(group),
        0,
        &if(&1["room_id"] == room_id, do: &1["room_index"])
      )

  defp cash_payment_target(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        {:error, "operation_not_found"}

      operation ->
        result = Jason.decode!(operation.result_json)

        if operation.type == "record_cash_payment" and result["status"] == "applied" and
             is_binary(result["group_id"]) and is_integer(result["amount_cents"]),
           do: {:ok, operation, result["group_id"], result["amount_cents"]},
           else: {:error, "payment_not_reducible"}
    end
  end

  defp payment_statement(operation) do
    result = Jason.decode!(operation.result_json)

    if operation.type != "record_cash_payment" or result["status"] != "applied" do
      {:not_reconcilable}
    else
      payment = Repo.get(CashPayment, operation.operation_id)
      legacy = if payment, do: nil, else: legacy_payment_state(operation, result)

      payment =
        payment ||
          %CashPayment{
            payment_operation_id: operation.operation_id,
            group_id: result["group_id"],
            recorded_cents: result["amount_cents"],
            refunded_cents: legacy.refunded_cents,
            retained_cents: legacy.retained_cents,
            converted_to_credit_cents: legacy.converted_to_credit_cents,
            reduced_cents: legacy.reduced_cents,
            charged_back_cents: legacy.charged_back_cents
          }

      held_cents =
        if legacy, do: legacy.held_cents, else: held_cents_for_payment(operation.operation_id)

      statement = %{
        "payment_operation_id" => operation.operation_id,
        "original_group_id" => result["group_id"],
        "recorded_cents" => result["amount_cents"],
        "held_cents" => held_cents,
        "refunded_cents" => payment.refunded_cents,
        "retained_cents" => payment.retained_cents,
        "converted_to_credit_cents" => payment.converted_to_credit_cents,
        "reduced_cents" => payment.reduced_cents,
        "charged_back_cents" => payment.charged_back_cents
      }

      statement =
        if payment.transferred,
          do: Map.put(statement, "held_by_group", held_cash_by_group(operation.operation_id)),
          else: statement

      {:ok, statement}
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id
    )
    |> Enum.group_by(& &1.group_id)
    |> Enum.map(fn {group_id, allocations} ->
      {group_id, Enum.reduce(allocations, 0, &(&1.amount_cents + &2))}
    end)
    |> Enum.filter(fn {_group_id, amount_cents} -> amount_cents > 0 end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  defp legacy_payment_state(operation, result) do
    group = Repo.get(Group, result["group_id"])
    recorded_cents = result["amount_cents"]

    if group && group.status == @active_status do
      %{
        held_cents: recorded_cents,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0
      }
    else
      cancellation =
        Repo.all(from candidate in Operation, order_by: [asc: candidate.commit_order])
        |> Enum.find(fn candidate ->
          candidate.commit_order > operation.commit_order and candidate.type == "cancel_group" and
            case Jason.decode(candidate.result_json) do
              {:ok, %{"status" => "applied", "group_id" => group_id}} ->
                group_id == result["group_id"]

              _ ->
                false
            end
        end)

      cancellation_result =
        if cancellation, do: Jason.decode!(cancellation.result_json), else: %{}

      cond do
        cancellation_result["refunded_cents"] && cancellation_result["refunded_cents"] > 0 ->
          %{
            held_cents: 0,
            refunded_cents: recorded_cents,
            retained_cents: 0,
            converted_to_credit_cents: 0,
            reduced_cents: 0,
            charged_back_cents: 0
          }

        cancellation_result["retained_cents"] && cancellation_result["retained_cents"] > 0 ->
          %{
            held_cents: 0,
            refunded_cents: 0,
            retained_cents: recorded_cents,
            converted_to_credit_cents: 0,
            reduced_cents: 0,
            charged_back_cents: 0
          }

        cancellation_result["credit_issued_cents"] &&
            cancellation_result["credit_issued_cents"] > 0 ->
          %{
            held_cents: 0,
            refunded_cents: 0,
            retained_cents: 0,
            converted_to_credit_cents: recorded_cents,
            reduced_cents: 0,
            charged_back_cents: 0
          }

        true ->
          %{
            held_cents: 0,
            refunded_cents: 0,
            retained_cents: 0,
            converted_to_credit_cents: 0,
            reduced_cents: 0,
            charged_back_cents: 0
          }
      end
    end
  end

  defp payment_amount(operation) do
    case Map.get(operation, "amount_cents") do
      amount_cents when is_integer(amount_cents) and amount_cents > 0 -> {:ok, amount_cents}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp payment_fits(amount_cents, outstanding_deposit_cents),
    do: if(amount_cents <= outstanding_deposit_cents, do: :ok, else: :payment_exceeds_outstanding)

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, "invalid_refund_method"}
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) in [:lt, :eq]
    end
  end

  defp outstanding_deposit(%Group{status: @active_status} = group),
    do: max((group.deposit_due_cents || 0) - (group.deposit_paid_cents || 0), 0)

  defp outstanding_deposit(%Group{}), do: 0

  defp cash_paid(%Group{cash_paid_cents: nil, deposit_paid_cents: deposit_paid_cents}),
    do: deposit_paid_cents || 0

  defp cash_paid(%Group{cash_paid_cents: cash_paid_cents}), do: cash_paid_cents || 0
  defp credit_paid(%Group{credit_paid_cents: credit_paid_cents}), do: credit_paid_cents || 0

  defp operation_type(operation) when is_map(operation), do: Map.get(operation, "type")
  defp operation_type(_operation), do: nil

  defp operation_id(operation) when is_map(operation),
    do:
      if(valid_identifier?(Map.get(operation, "operation_id")),
        do: {:ok, Map.get(operation, "operation_id")},
        else: {:error, "invalid_operation"}
      )

  defp operation_id(_operation), do: {:error, "invalid_operation"}

  defp operation_id_value(operation) when is_map(operation),
    do: Map.get(operation, "operation_id")

  defp operation_id_value(_operation), do: nil

  defp required_identifier(operation, key),
    do:
      if(is_map(operation) and valid_identifier?(Map.get(operation, key)),
        do: {:ok, Map.get(operation, key)},
        else: {:error, "invalid_operation"}
      )

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp required_date(operation, key) when is_map(operation) do
    case Map.get(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp required_date(_operation, _key), do: {:error, "invalid_stay"}

  defp rejected(operation, code, extra \\ %{}),
    do:
      {:rejected,
       Map.merge(
         %{
           "operation_id" => operation_id_value(operation),
           "status" => "rejected",
           "code" => code
         },
         extra
       )}

  defp policy_version(rate_plan, booked_on) do
    cond do
      rate_plan == "advance_purchase" -> "advance-nonrefundable"
      Date.compare(booked_on, @policy_cutover) == :lt -> "flex-14"
      true -> "flex-30"
    end
  end

  defp policy_version(%Group{policy_version: policy_version})
       when is_binary(policy_version) and policy_version != "", do: policy_version

  defp policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version(rate_plan, booked_on)

  defp policy_window("flex-14"), do: 14
  defp policy_window("flex-30"), do: 30
  defp policy_window("advance-nonrefundable"), do: nil

  defp refundable_until(%Group{} = group) do
    case policy_window(policy_version(group)) do
      nil -> nil
      window -> Date.add(group.arrival_on, -window)
    end
  end

  defp refundable_until_json(group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp public_credit_lot(lot),
    do: %{
      "source_operation_id" => lot.source_operation_id,
      "remaining_cents" => lot.remaining_cents,
      "expires_on" => Date.to_iso8601(lot.expires_on)
    }

  defp round_percentage(amount, numerator, denominator) do
    quotient = div(amount * numerator, denominator)
    remainder = rem(amount * numerator, denominator)
    if remainder * 2 >= denominator, do: quotient + 1, else: quotient
  end

  defp valid_stay(arrival_on, departure_on),
    do: if(Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: :invalid_stay)

  defp reschedule_date_is_valid(occurred_on, new_arrival_on),
    do: if(Date.compare(new_arrival_on, occurred_on) == :gt, do: :ok, else: :invalid_stay)

  defp valid_rate_plan(operation) do
    case Map.get(operation, "rate_plan") do
      rate_plan when rate_plan in @rate_plans -> {:ok, rate_plan}
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp room_identifier(room) when is_map(room) do
    case Map.get(room, "room_id") do
      room_id when is_binary(room_id) and byte_size(room_id) > 0 -> {:ok, room_id}
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp room_identifier(_), do: {:error, "invalid_rooms"}

  defp unique_room_id(room_id, ids),
    do: if(MapSet.member?(ids, room_id), do: {:error, "invalid_rooms"}, else: :ok)

  defp nightly_rate(room) do
    if is_map(room) do
      case Map.get(room, "nightly_rate_cents") do
        rate when is_integer(rate) and rate > 0 -> {:ok, rate}
        _ -> {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end
end
