defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{
    AllocationOrder,
    CashAllocation,
    CreditAllocation,
    CreditLot,
    CreditLotContribution,
    FinanceReportEvent,
    FinanceReporting,
    Group,
    LedgerEntry,
    OperationRecord,
    PaymentAccounting,
    PaymentPropertyAccounting,
    Repo,
    Room
  }

  @operation_types ~w(
    open_group
    record_cash_payment
    apply_hotel_credit
    reschedule_group
    cancel_group
    cancel_rooms
    transfer_deposit
    reduce_cash_payment
    charge_back_payment
    start_finance_reporting
  )

  @disposition_kinds ~w(refunded retained converted_to_credit)
  @cash_movement_kinds ~w(
    received_cents
    transferred_in_cents
    transferred_out_cents
    refunded_cents
    retained_cents
    converted_to_credit_cents
    reduced_cents
    charged_back_cents
  )
  @credit_movement_kinds ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  @spec process_batch([map()]) :: [map()]
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @spec get_group(String.t()) :: {:ok, map()} | :error
  def get_group(group_id) do
    case Repo.transaction(fn ->
           case Repo.get_by(Group, group_id: group_id) do
             nil ->
               :error

             group ->
               ensure_group_accounting(group)
               group = Repo.get!(Group, group.id)
               rooms = rooms_for(group.id)
               render_group(group, rooms)
           end
         end) do
      {:ok, result} ->
        case result do
          :error -> :error
          group -> {:ok, group}
        end

      {:error, _reason} ->
        :error
    end
  end

  @doc false
  def backfill_all_groups do
    Repo.all(Group)
    |> Enum.each(fn group ->
      case Repo.transaction(fn -> ensure_group_accounting(group) end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> raise "room accounting backfill failed: #{inspect(reason)}"
      end
    end)

    :ok
  end

  @doc false
  def backfill_allocation_orders do
    Repo.all(from group in Group, order_by: [asc: group.id])
    |> Enum.each(fn group ->
      case Repo.transaction(fn ->
             cash_allocations =
               Repo.all(
                 from allocation in CashAllocation,
                   where: allocation.group_id == ^group.id,
                   order_by: [asc: allocation.id]
               )

             credit_allocations =
               Repo.all(
                 from allocation in CreditAllocation,
                   where: allocation.group_id == ^group.id,
                   order_by: [asc: allocation.id]
               )

             records = durable_funding_records(group.group_id)

             legacy =
               Enum.filter(cash_allocations, &is_nil(&1.payment_operation_id)) ++
                 Enum.filter(credit_allocations, &is_nil(&1.funding_operation_id))

             durable =
               Enum.reduce(records, [], fn record, allocations ->
                 source_allocations =
                   case record.type do
                     "record_cash_payment" ->
                       Enum.filter(
                         cash_allocations,
                         &(&1.payment_operation_id == record.operation_id)
                       )

                     "apply_hotel_credit" ->
                       Enum.filter(
                         credit_allocations,
                         &(&1.funding_operation_id == record.operation_id)
                       )
                   end

                 allocations ++ source_allocations
               end)

             ordered =
               (legacy ++ durable ++ cash_allocations ++ credit_allocations)
               |> Enum.uniq_by(&allocation_key/1)

             Enum.each(ordered, fn allocation ->
               Repo.update!(
                 Ecto.Changeset.change(allocation, allocation_order: next_allocation_order())
               )
             end)
           end) do
        {:ok, :ok} -> :ok
        {:ok, _result} -> :ok
        {:error, reason} -> raise "allocation order backfill failed: #{inspect(reason)}"
      end
    end)

    :ok
  end

  @spec get_operation(String.t()) :: {:ok, map()} | :error
  def get_operation(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> :error
      record -> {:ok, record.result}
    end
  end

  @spec daily_finance_report(Date.t()) :: {:ok, map()} | {:error, :not_available}
  def daily_finance_report(date) do
    case Repo.one(from reporting in FinanceReporting, limit: 1) do
      nil ->
        {:error, :not_available}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, :not_available}
        else
          events =
            Repo.all(
              from event in FinanceReportEvent,
                where: event.posting_on <= ^date,
                order_by: [asc: event.posting_on, asc: event.id]
            )

          cash_before = cash_balances_before(reporting.opening_cash, events, date)
          cash_today = cash_movements_for(events, date)
          credit_movements = credit_movements_by_date(reporting, events, date)

          {:ok,
           %{
             "date" => Date.to_iso8601(date),
             "status" => "open",
             "cash" => render_daily_cash(cash_before, cash_today),
             "credit" => render_daily_credit(reporting, credit_movements, date)
           }}
        end
    end
  end

  @spec parse_required_report_date(term()) :: {:ok, Date.t()} | {:error, :invalid_date}
  def parse_required_report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  def parse_required_report_date(_value), do: {:error, :invalid_date}

  defp cash_balances_before(opening_cash, events, date) do
    events
    |> Enum.filter(&(Date.compare(&1.posting_on, date) == :lt))
    |> Enum.reduce(opening_cash || %{}, fn event, balances ->
      add_cash_balances(balances, event.cash_movements || %{})
    end)
  end

  defp cash_movements_for(events, date) do
    events
    |> Enum.filter(&(Date.compare(&1.posting_on, date) == :eq))
    |> Enum.reduce(%{}, fn event, movements ->
      merge_cash_movements(movements, event.cash_movements || %{})
    end)
  end

  defp add_cash_balances(balances, movements) do
    Enum.reduce(movements, balances, fn {property_id, movement}, balances ->
      Map.update(balances, property_id, cash_balance_delta(movement), fn balance ->
        balance + cash_balance_delta(movement)
      end)
    end)
  end

  defp merge_cash_movements(movements, event_movements) do
    Enum.reduce(event_movements, movements, fn {property_id, movement}, movements ->
      Map.update(movements, property_id, normalize_cash_movement(movement), fn existing ->
        merge_movement(existing, movement, @cash_movement_kinds)
      end)
    end)
  end

  defp render_daily_cash(opening_balances, today_movements) do
    properties =
      (Map.keys(opening_balances) ++ Map.keys(today_movements)) |> Enum.uniq() |> Enum.sort()

    Enum.reduce(properties, [], fn property_id, entries ->
      opening = Map.get(opening_balances, property_id, 0)
      movement = Map.get(today_movements, property_id, empty_cash_movement())
      closing = opening + cash_balance_delta(movement)

      if opening != 0 or closing != 0 or Enum.any?(Map.values(movement), &(&1 != 0)) do
        [
          %{
            "property_id" => property_id,
            "opening_held_cents" => opening,
            "movements" => normalize_cash_movement(movement),
            "closing_held_cents" => closing
          }
          | entries
        ]
      else
        entries
      end
    end)
    |> Enum.reverse()
  end

  defp credit_movements_by_date(reporting, events, date) do
    state = normalize_opening_credit_lots(reporting.opening_credit_lots || %{})

    {_state, movements} =
      Enum.reduce(events, {state, %{}}, fn event, {state, movements} ->
        {state, movements} = expire_credit_lots(state, event.posting_on, movements)

        {state, movements} =
          apply_credit_lot_changes(
            state,
            event.credit_lot_changes || %{},
            event.posting_on,
            movements
          )

        movements =
          add_credit_movements(movements, event.posting_on, event.credit_movements || %{})

        {state, movements}
      end)

    {_state, movements} = expire_credit_lots(state, date, movements)
    movements
  end

  defp normalize_opening_credit_lots(lots) do
    Map.new(lots, fn {lot_id, lot} ->
      {lot_id,
       %{
         available_cents: lot["available_cents"] || 0,
         expires_on: Date.from_iso8601!(lot["expires_on"]),
         expired: false
       }}
    end)
  end

  defp expire_credit_lots(state, target_date, movements) do
    Enum.reduce(state, {state, movements}, fn {lot_id, lot}, {state, movements} ->
      expiration_date = lot.expires_on

      if not lot.expired and lot.available_cents > 0 and
           Date.compare(expiration_date, target_date) != :gt do
        movements =
          add_credit_movement(movements, expiration_date, "expired_cents", lot.available_cents)

        {Map.put(state, lot_id, %{lot | available_cents: 0, expired: true}), movements}
      else
        {state, movements}
      end
    end)
  end

  defp apply_credit_lot_changes(state, changes, posting_on, movements) do
    Enum.reduce(changes, {state, movements}, fn {lot_id, change}, {state, movements} ->
      new_lot? = not Map.has_key?(state, lot_id)

      expires_on =
        case Map.get(change, "expires_on") do
          value when is_binary(value) -> Date.from_iso8601!(value)
          _ -> Map.get(state, lot_id, %{expires_on: posting_on}).expires_on
        end

      lot =
        Map.get(state, lot_id, %{
          available_cents: 0,
          expires_on: expires_on,
          expired: false
        })

      delta = Map.get(change, "available_delta_cents", 0) || 0

      available_cents =
        if delta > 0 and (lot.expired or Date.compare(expires_on, posting_on) != :gt) do
          lot.available_cents
        else
          max(lot.available_cents + delta, 0)
        end

      immediately_expired? =
        new_lot? and delta > 0 and Date.compare(expires_on, posting_on) != :gt

      if immediately_expired? do
        movements = add_credit_movement(movements, posting_on, "expired_cents", delta)

        {Map.put(state, lot_id, %{lot | available_cents: 0, expires_on: expires_on, expired: true}),
         movements}
      else
        {Map.put(state, lot_id, %{lot | available_cents: available_cents, expires_on: expires_on}),
         movements}
      end
    end)
  end

  defp add_credit_movements(movements, date, event_movements) do
    Enum.reduce(event_movements, movements, fn {kind, amount}, movements ->
      add_credit_movement(movements, date, kind, amount)
    end)
  end

  defp add_credit_movement(movements, date, kind, amount) when is_integer(amount) do
    date = Date.to_iso8601(date)

    Map.update(movements, date, Map.put(empty_credit_movement(), kind, amount), fn existing ->
      Map.update(existing, kind, amount, &(&1 + amount))
    end)
  end

  defp add_credit_movement(movements, _date, _kind, _amount), do: movements

  defp render_daily_credit(reporting, movements, date) do
    opening_liability =
      movements
      |> Enum.filter(fn {movement_date, _movement} -> movement_date < Date.to_iso8601(date) end)
      |> Enum.reduce(reporting.opening_credit_liability_cents, fn {_date, movement}, liability ->
        liability + credit_liability_delta(movement)
      end)

    today = Map.get(movements, Date.to_iso8601(date), empty_credit_movement())
    closing = opening_liability + credit_liability_delta(today)

    %{
      "opening_liability_cents" => opening_liability,
      "movements" => normalize_credit_movement(today),
      "closing_liability_cents" => closing
    }
  end

  defp merge_movement(existing, incoming, kinds) do
    Enum.reduce(kinds, existing, fn kind, merged ->
      Map.put(merged, kind, Map.get(merged, kind, 0) + (Map.get(incoming, kind, 0) || 0))
    end)
  end

  defp normalize_cash_movement(movement) do
    Map.new(@cash_movement_kinds, &{&1, Map.get(movement, &1, 0) || 0})
  end

  defp normalize_credit_movement(movement) do
    Map.new(@credit_movement_kinds, &{&1, Map.get(movement, &1, 0) || 0})
  end

  defp empty_cash_movement, do: Map.new(@cash_movement_kinds, &{&1, 0})
  defp empty_credit_movement, do: Map.new(@credit_movement_kinds, &{&1, 0})

  defp cash_balance_delta(movement) do
    Map.get(movement, "received_cents", 0) +
      Map.get(movement, "transferred_in_cents", 0) -
      Map.get(movement, "transferred_out_cents", 0) -
      Map.get(movement, "refunded_cents", 0) -
      Map.get(movement, "retained_cents", 0) -
      Map.get(movement, "converted_to_credit_cents", 0) -
      Map.get(movement, "reduced_cents", 0) -
      Map.get(movement, "charged_back_cents", 0)
  end

  defp credit_liability_delta(movement) do
    Map.get(movement, "issued_cents", 0) -
      Map.get(movement, "expired_cents", 0) -
      Map.get(movement, "consumed_cents", 0) -
      Map.get(movement, "revoked_cents", 0) -
      Map.get(movement, "absorbed_cents", 0)
  end

  defp ensure_all_groups_accounting do
    Repo.all(from group in Group, order_by: [asc: group.id])
    |> Enum.each(&ensure_group_accounting/1)

    Repo.all(from accounting in PaymentAccounting, select: accounting.payment_operation_id)
    |> Enum.each(&ensure_payment_property_accounting(nil, &1))
  end

  defp reporting_snapshot do
    cash_by_property =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          join: group in Group,
          on: group.id == allocation.group_id,
          where: room.status == "active" and group.status == "active",
          group_by: group.property_id,
          select: {group.property_id, sum(allocation.amount_cents)}
      )
      |> Map.new(fn {property_id, amount} -> {property_id, amount || 0} end)

    cash_by_group =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          join: group in Group,
          on: group.id == allocation.group_id,
          where: room.status == "active" and group.status == "active",
          group_by: group.group_id,
          select: {group.group_id, sum(allocation.amount_cents)}
      )
      |> Map.new(fn {group_id, amount} -> {group_id, amount || 0} end)

    group_properties =
      Repo.all(from group in Group, select: {group.group_id, group.property_id}) |> Map.new()

    payment_dispositions =
      Repo.all(
        from accounting in PaymentPropertyAccounting,
          join: group in Group,
          on: group.id == accounting.group_id,
          select: {
            accounting.payment_operation_id,
            group.property_id,
            accounting.held_cents,
            accounting.refunded_cents,
            accounting.retained_cents,
            accounting.converted_to_credit_cents,
            accounting.reduced_cents,
            accounting.charged_back_cents
          }
      )
      |> Enum.reduce(%{}, fn {payment_id, property_id, held, refunded, retained, converted,
                              reduced, charged_back},
                             dispositions ->
        property_disposition = %{
          "held_cents" => held || 0,
          "refunded_cents" => refunded || 0,
          "retained_cents" => retained || 0,
          "converted_to_credit_cents" => converted || 0,
          "reduced_cents" => reduced || 0,
          "charged_back_cents" => charged_back || 0
        }

        Map.update(
          dispositions,
          payment_id,
          %{property_id => property_disposition},
          fn existing ->
            Map.update(existing, property_id, property_disposition, fn current ->
              merge_movement(current, property_disposition, Map.keys(property_disposition))
            end)
          end
        )
      end)

    credit_lots =
      Repo.all(from lot in CreditLot, order_by: [asc: lot.id])
      |> Enum.map(fn lot ->
        applied =
          Repo.one(
            from allocation in CreditAllocation,
              join: group in Group,
              on: group.id == allocation.group_id,
              where: allocation.credit_lot_id == ^lot.id and group.status == "active",
              select: sum(allocation.amount_cents)
          ) || 0

        {Integer.to_string(lot.id),
         %{
           "remaining_cents" => lot.remaining_cents || 0,
           "applied_cents" => applied,
           "unrecovered_clawback_cents" => lot.unrecovered_clawback_cents || 0,
           "expires_on" => Date.to_iso8601(lot.expires_on)
         }}
      end)
      |> Map.new()

    %{
      cash_by_property: cash_by_property,
      cash_by_group: cash_by_group,
      group_properties: group_properties,
      payment_dispositions: payment_dispositions,
      credit_lots: credit_lots
    }
  end

  defp opening_credit_lots(credit_lots) do
    today = Date.utc_today()

    credit_lots
    |> Enum.reduce(%{}, fn {lot_id, lot}, opening ->
      available =
        if Date.compare(Date.from_iso8601!(lot["expires_on"]), today) == :gt,
          do: lot["remaining_cents"],
          else: 0

      if available > 0 or lot["applied_cents"] > 0 do
        Map.put(opening, lot_id, %{
          "available_cents" => available,
          "applied_cents" => lot["applied_cents"],
          "expires_on" => lot["expires_on"]
        })
      else
        opening
      end
    end)
  end

  defp record_finance_event(operation, reporting, before, result) do
    after_snapshot = reporting_snapshot()
    occurred_on = Date.from_iso8601!(operation["occurred_on"])

    posting_on =
      if Date.compare(occurred_on, reporting.starts_on) == :lt,
        do: reporting.starts_on,
        else: occurred_on

    Repo.insert!(%FinanceReportEvent{
      operation_id: operation["operation_id"],
      posting_on: posting_on,
      cash_movements: finance_cash_movements(operation, before, after_snapshot),
      credit_movements: finance_credit_movements(operation, before, after_snapshot, result),
      credit_lot_changes: credit_lot_changes(before.credit_lots, after_snapshot.credit_lots)
    })
  end

  defp finance_cash_movements(operation, before, after_snapshot) do
    case operation["type"] do
      "record_cash_payment" ->
        add_cash_movement(
          %{},
          before.group_properties[operation["group_id"]],
          "received_cents",
          operation["amount_cents"]
        )

      "transfer_deposit" ->
        source = operation["source_group_id"]
        destination = operation["destination_group_id"]

        source_moved =
          Map.get(before.cash_by_group, source, 0) -
            Map.get(after_snapshot.cash_by_group, source, 0)

        destination_moved =
          Map.get(after_snapshot.cash_by_group, destination, 0) -
            Map.get(before.cash_by_group, destination, 0)

        %{}
        |> add_cash_movement(
          %{property_id: before.group_properties[source]},
          "transferred_out_cents",
          source_moved
        )
        |> add_cash_movement(
          %{property_id: before.group_properties[destination]},
          "transferred_in_cents",
          destination_moved
        )

      "cancel_group" ->
        cancellation_cash_movement(operation, before, after_snapshot)

      "cancel_rooms" ->
        cancellation_cash_movement(operation, before, after_snapshot)

      "reduce_cash_payment" ->
        cash_held_changes(before, after_snapshot, "reduced_cents")

      "charge_back_payment" ->
        chargeback_cash_movements(operation, before, after_snapshot)

      _ ->
        %{}
    end
  end

  defp cancellation_cash_movement(operation, before, after_snapshot) do
    group_id = operation["group_id"]

    removed =
      Map.get(before.cash_by_group, group_id, 0) -
        Map.get(after_snapshot.cash_by_group, group_id, 0)

    group = Repo.get_by!(Group, group_id: group_id)
    occurred_on = Date.from_iso8601!(operation["occurred_on"])
    method = Map.get(operation, "refund_method", "cash")

    kind =
      cond do
        refundable?(group, occurred_on) and method == "hotel_credit" ->
          "converted_to_credit_cents"

        refundable?(group, occurred_on) ->
          "refunded_cents"

        true ->
          "retained_cents"
      end

    add_cash_movement(%{}, group.property_id, kind, removed)
  end

  defp cash_held_changes(before, after_snapshot, kind) do
    properties =
      (Map.keys(before.cash_by_property) ++ Map.keys(after_snapshot.cash_by_property))
      |> Enum.uniq()

    Enum.reduce(properties, %{}, fn property_id, movements ->
      removed =
        Map.get(before.cash_by_property, property_id, 0) -
          Map.get(after_snapshot.cash_by_property, property_id, 0)

      add_cash_movement(movements, property_id, kind, removed)
    end)
  end

  defp chargeback_cash_movements(operation, before, after_snapshot) do
    payment_id = operation["payment_operation_id"]
    before_properties = Map.get(before.payment_dispositions, payment_id, %{})
    after_properties = Map.get(after_snapshot.payment_dispositions, payment_id, %{})
    properties = (Map.keys(before_properties) ++ Map.keys(after_properties)) |> Enum.uniq()

    Enum.reduce(properties, %{}, fn property_id, movements ->
      old = Map.get(before_properties, property_id, %{})
      new = Map.get(after_properties, property_id, %{})

      movements
      |> add_cash_movement(
        property_id,
        "refunded_cents",
        Map.get(new, "refunded_cents", 0) - Map.get(old, "refunded_cents", 0)
      )
      |> add_cash_movement(
        property_id,
        "retained_cents",
        Map.get(new, "retained_cents", 0) - Map.get(old, "retained_cents", 0)
      )
      |> add_cash_movement(
        property_id,
        "converted_to_credit_cents",
        Map.get(new, "converted_to_credit_cents", 0) -
          Map.get(old, "converted_to_credit_cents", 0)
      )
      |> add_cash_movement(
        property_id,
        "charged_back_cents",
        Map.get(new, "charged_back_cents", 0) - Map.get(old, "charged_back_cents", 0)
      )
    end)
    |> then(fn movements ->
      held_removed =
        Enum.reduce(properties, %{}, fn property_id, held ->
          old = Map.get(before_properties, property_id, %{})
          new = Map.get(after_properties, property_id, %{})

          add_cash_movement(
            held,
            property_id,
            "charged_back_cents",
            Map.get(old, "held_cents", 0) - Map.get(new, "held_cents", 0)
          )
        end)

      merge_cash_movements(movements, held_removed)
    end)
  end

  defp add_cash_movement(movements, %{property_id: property_id}, kind, amount),
    do: add_cash_movement(movements, property_id, kind, amount)

  defp add_cash_movement(movements, property_id, kind, amount)
       when is_binary(property_id) and is_integer(amount) and amount != 0 do
    Map.update(movements, property_id, %{kind => amount}, fn existing ->
      Map.update(existing, kind, amount, &(&1 + amount))
    end)
  end

  defp add_cash_movement(movements, _property_id, _kind, _amount), do: movements

  defp finance_credit_movements(operation, before, after_snapshot, result) do
    case operation["type"] do
      type when type in ["cancel_group", "cancel_rooms"] ->
        credit_cancellation_movements(operation, before, after_snapshot)

      "charge_back_payment" ->
        occurred_on = Date.from_iso8601!(operation["occurred_on"])

        revoked =
          before.credit_lots
          |> Enum.reduce(0, fn {lot_id, old}, total ->
            new = Map.get(after_snapshot.credit_lots, lot_id, old)

            if Date.compare(Date.from_iso8601!(old["expires_on"]), occurred_on) == :gt do
              total + max(old["remaining_cents"] - new["remaining_cents"], 0)
            else
              total
            end
          end)

        if revoked > 0, do: %{"revoked_cents" => revoked}, else: %{}

      _ ->
        %{}
    end
    |> maybe_add_credit_issue(result)
  end

  defp maybe_add_credit_issue(movements, result) do
    issued = result["credit_issued_cents"] || 0

    if issued > 0,
      do: Map.update(movements, "issued_cents", issued, &(&1 + issued)),
      else: movements
  end

  defp credit_cancellation_movements(operation, before, after_snapshot) do
    applied_removed =
      before.credit_lots
      |> Enum.reduce(0, fn {lot_id, old}, total ->
        new = Map.get(after_snapshot.credit_lots, lot_id, old)
        total + max(old["applied_cents"] - new["applied_cents"], 0)
      end)

    if applied_removed == 0 do
      %{}
    else
      group = Repo.get_by!(Group, group_id: operation["group_id"])
      occurred_on = Date.from_iso8601!(operation["occurred_on"])

      if refundable?(group, occurred_on) do
        restored =
          before.credit_lots
          |> Enum.reduce(0, fn {lot_id, old}, total ->
            new = Map.get(after_snapshot.credit_lots, lot_id, old)
            total + max(new["remaining_cents"] - old["remaining_cents"], 0)
          end)

        absorbed =
          before.credit_lots
          |> Enum.reduce(0, fn {lot_id, old}, total ->
            new = Map.get(after_snapshot.credit_lots, lot_id, old)
            total + max(old["unrecovered_clawback_cents"] - new["unrecovered_clawback_cents"], 0)
          end)

        expired = max(applied_removed - restored - absorbed, 0)

        %{}
        |> maybe_put_credit("expired_cents", expired)
        |> maybe_put_credit("absorbed_cents", absorbed)
      else
        %{"consumed_cents" => applied_removed}
      end
    end
  end

  defp maybe_put_credit(movements, _kind, 0), do: movements
  defp maybe_put_credit(movements, kind, amount), do: Map.put(movements, kind, amount)

  defp credit_lot_changes(before_lots, after_lots) do
    lot_ids = (Map.keys(before_lots) ++ Map.keys(after_lots)) |> Enum.uniq()

    Enum.reduce(lot_ids, %{}, fn lot_id, changes ->
      before = Map.get(before_lots, lot_id)
      after_lot = Map.get(after_lots, lot_id)

      before_remaining = if before, do: before["remaining_cents"], else: 0
      after_remaining = if after_lot, do: after_lot["remaining_cents"], else: 0
      before_applied = if before, do: before["applied_cents"], else: 0
      after_applied = if after_lot, do: after_lot["applied_cents"], else: 0
      before_unrecovered = if before, do: before["unrecovered_clawback_cents"], else: 0

      after_unrecovered =
        if after_lot, do: after_lot["unrecovered_clawback_cents"], else: 0

      if before_remaining != after_remaining or before_applied != after_applied or
           before_unrecovered != after_unrecovered do
        Map.put(changes, lot_id, %{
          "available_delta_cents" => after_remaining - before_remaining,
          "applied_delta_cents" => after_applied - before_applied,
          "unrecovered_delta_cents" => after_unrecovered - before_unrecovered,
          "expires_on" => (after_lot || before)["expires_on"]
        })
      else
        changes
      end
    end)
  end

  @spec get_payment_reconciliation(String.t()) ::
          {:ok, map()} | {:error, :not_found | :not_reconcilable}
  def get_payment_reconciliation(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :not_found}

      %OperationRecord{type: "record_cash_payment", result: %{"status" => "applied"} = result} ->
        case Repo.get_by(PaymentAccounting, payment_operation_id: payment_operation_id) do
          nil ->
            {:ok, legacy_payment_reconciliation(result, payment_operation_id)}

          accounting ->
            reconciliation = %{
              "payment_operation_id" => payment_operation_id,
              "original_group_id" => result["group_id"],
              "recorded_cents" => accounting.recorded_cents,
              "held_cents" => accounting.held_cents,
              "refunded_cents" => accounting.refunded_cents,
              "retained_cents" => accounting.retained_cents,
              "converted_to_credit_cents" => accounting.converted_to_credit_cents,
              "reduced_cents" => accounting.reduced_cents,
              "charged_back_cents" => accounting.charged_back_cents
            }

            if accounting.transfer_participated do
              {:ok,
               Map.put(reconciliation, "held_by_group", held_cash_by_group(payment_operation_id))}
            else
              {:ok, reconciliation}
            end
        end

      _record ->
        {:error, :not_reconcilable}
    end
  end

  defp legacy_payment_reconciliation(result, payment_operation_id) do
    recorded = result["amount_cents"] || 0

    disposition =
      case Repo.get_by(Group, group_id: result["group_id"]) do
        %Group{} = group ->
          dispositions =
            durable_funding_records(group.group_id)
            |> Enum.filter(&(&1.type == "record_cash_payment"))
            |> then(&backfilled_dispositions(group, &1))

          Map.get(dispositions, payment_operation_id, %{})

        nil ->
          %{}
      end

    %{
      "payment_operation_id" => payment_operation_id,
      "original_group_id" => result["group_id"],
      "recorded_cents" => recorded,
      "held_cents" => Map.get(disposition, :held, if(disposition == %{}, do: recorded, else: 0)),
      "refunded_cents" => Map.get(disposition, :refunded, 0),
      "retained_cents" => Map.get(disposition, :retained, 0),
      "converted_to_credit_cents" => Map.get(disposition, :converted_to_credit, 0),
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.id == allocation.group_id,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            room.status == "active" and group.status == "active",
        group_by: group.group_id,
        select: {group.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {group_id, amount} ->
      %{"group_id" => group_id, "amount_cents" => amount || 0}
    end)
  end

  @spec credit_for_guest(String.t(), Date.t()) :: map()
  def credit_for_guest(guest_id, as_of) do
    lots = available_credit_lots(guest_id, as_of)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  @spec parse_report_date(term()) :: {:ok, Date.t()} | {:error, :invalid_date}
  def parse_report_date(nil), do: {:ok, Date.utc_today()}

  def parse_report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  def parse_report_date(_value), do: {:error, :invalid_date}

  @spec ledger_totals(Date.t()) :: map()
  def ledger_totals(as_of) do
    legacy_totals =
      Repo.all(
        from entry in LedgerEntry,
          group_by: entry.kind,
          select: {entry.kind, sum(entry.amount_cents)}
      )
      |> Map.new(fn {kind, amount} -> {kind, amount || 0} end)

    account_totals =
      Repo.one(
        from accounting in PaymentAccounting,
          select: %{
            recorded: sum(accounting.recorded_cents),
            held: sum(accounting.held_cents),
            refunded: sum(accounting.refunded_cents),
            retained: sum(accounting.retained_cents),
            converted: sum(accounting.converted_to_credit_cents),
            reduced: sum(accounting.reduced_cents),
            charged_back: sum(accounting.charged_back_cents)
          }
      ) || %{}

    backfilled_totals =
      Repo.one(
        from accounting in PaymentAccounting,
          where: accounting.backfilled == true,
          select: %{
            recorded: sum(accounting.recorded_cents),
            refunded: sum(accounting.backfilled_refunded_cents),
            retained: sum(accounting.backfilled_retained_cents),
            converted: sum(accounting.backfilled_converted_to_credit_cents)
          }
      ) || %{}

    account_recorded = Map.get(backfilled_totals, :recorded, 0) || 0
    legacy_recorded = max(Map.get(legacy_totals, "held", 0) - account_recorded, 0)

    refunded = Map.get(account_totals, :refunded, 0) || 0
    retained = Map.get(account_totals, :retained, 0) || 0
    converted = Map.get(account_totals, :converted, 0) || 0
    reduced = Map.get(account_totals, :reduced, 0) || 0
    charged_back = Map.get(account_totals, :charged_back, 0) || 0

    legacy_refunded =
      max(
        Map.get(legacy_totals, "refunded", 0) - (Map.get(backfilled_totals, :refunded, 0) || 0),
        0
      )

    legacy_retained =
      max(
        Map.get(legacy_totals, "retained", 0) - (Map.get(backfilled_totals, :retained, 0) || 0),
        0
      )

    legacy_converted =
      max(
        Map.get(legacy_totals, "converted_to_credit", 0) -
          (Map.get(backfilled_totals, :converted, 0) || 0),
        0
      )

    legacy_reduced =
      max(
        Map.get(legacy_totals, "reduced", 0) - (Map.get(backfilled_totals, :reduced, 0) || 0),
        0
      )

    legacy_charged_back =
      max(
        Map.get(legacy_totals, "charged_back", 0) -
          (Map.get(backfilled_totals, :charged_back, 0) || 0),
        0
      )

    %{
      "cash_held_cents" =>
        (Map.get(account_totals, :held, 0) || 0) +
          max(
            legacy_recorded - legacy_refunded - legacy_retained - legacy_converted -
              legacy_reduced - legacy_charged_back,
            0
          ),
      "cash_refunded_cents" => refunded + legacy_refunded,
      "cash_retained_cents" => retained + legacy_retained,
      "cash_converted_to_credit_cents" => converted + legacy_converted,
      "cash_reduced_cents" => reduced + legacy_reduced,
      "cash_charged_back_cents" => charged_back + legacy_charged_back,
      "credit_liability_cents" => credit_liability(as_of),
      "credit_shortfall_cents" => credit_shortfall()
    }
  end

  def ledger_totals, do: ledger_totals(Date.utc_today())

  defp process_operation(operation) when not is_map(operation) do
    rejection(operation, "invalid_operation")
  end

  defp process_operation(operation) do
    case Repo.transaction(
           fn ->
             existing_record =
               if valid_identifier(Map.get(operation, "operation_id")),
                 do: Repo.get_by(OperationRecord, operation_id: operation["operation_id"])

             reporting = Repo.one(from configured in FinanceReporting, limit: 1)

             before = if reporting && is_nil(existing_record), do: reporting_snapshot()

             result =
               if valid_identifier(Map.get(operation, "operation_id")) do
                 process_durable_operation(operation)
               else
                 process_operation_once(operation)
               end

             if reporting && is_nil(existing_record) && result["status"] == "applied" &&
                  operation["type"] != "start_finance_reporting" do
               record_finance_event(operation, reporting, before, result)
             end

             result
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
    end
  end

  defp process_durable_operation(operation) do
    operation_id = operation["operation_id"]

    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil ->
        result = process_operation_once(operation)

        Repo.insert!(%OperationRecord{
          operation_id: operation_id,
          type: operation_type(operation["type"]),
          payload: operation,
          result: result
        })

        result

      %OperationRecord{payload: payload, result: result} when payload === operation ->
        result

      _record ->
        rejection(operation, "operation_id_conflict")
    end
  end

  defp process_operation_once(operation) do
    case Map.get(operation, "type") do
      "open_group" -> process_open_group(operation)
      "start_finance_reporting" -> process_start_finance_reporting(operation)
      type when type in @operation_types -> process_existing(operation, type)
      _ -> rejection(operation, "invalid_operation")
    end
  end

  defp process_start_finance_reporting(operation) do
    with {:ok, starts_on} <- reporting_date(operation["starts_on"]),
         :ok <- validate_common_fields(operation) do
      case Repo.one(from reporting in FinanceReporting, limit: 1) do
        nil ->
          ensure_all_groups_accounting()
          snapshot = reporting_snapshot()

          Repo.insert!(%FinanceReporting{
            starts_on: starts_on,
            opening_cash: snapshot.cash_by_property,
            opening_credit_liability_cents: credit_liability(Date.utc_today()),
            opening_credit_lots: opening_credit_lots(snapshot.credit_lots)
          })

          %{
            "operation_id" => operation["operation_id"],
            "status" => "applied",
            "starts_on" => Date.to_iso8601(starts_on)
          }

        _reporting ->
          rejection(operation, "reporting_already_started")
      end
    else
      {:error, code} -> rejection(operation, code)
    end
  end

  defp process_open_group(operation) do
    with :ok <- validate_common_fields(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms, lodging_total, deposit_due} <-
           validate_rooms(operation["rooms"], arrival_on, departure_on, rate_plan) do
      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version(rate_plan, booked_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      }

      insert_group(operation, attrs, rooms)
    else
      {:error, code} -> rejection(operation, code)
    end
  end

  defp insert_group(operation, attrs, rooms) do
    case Repo.get_by(Group, group_id: attrs.group_id) do
      nil ->
        group = Repo.insert!(struct(Group, attrs))

        Enum.each(rooms, fn room ->
          Repo.insert!(%Room{
            group_id: group.id,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            position: room.position,
            status: "active",
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: 0,
            credit_paid_cents: 0
          })
        end)

        %{
          "operation_id" => operation["operation_id"],
          "status" => "applied",
          "group_id" => group.group_id,
          "deposit_due_cents" => group.deposit_due_cents,
          "revision" => group.revision
        }

      _group ->
        rejection(operation, "group_already_exists", %{"group_id" => attrs.group_id})
    end
  end

  defp process_existing(operation, type)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    apply_payment_operation(operation, type)
  end

  defp process_existing(operation, "transfer_deposit"), do: apply_transfer(operation)

  defp process_existing(operation, type) do
    case required_identifier(operation, "group_id") do
      {:ok, group_id} ->
        apply_existing(operation, type, group_id)

      {:error, code} ->
        rejection(operation, code)
    end
  end

  defp apply_transfer(operation) do
    with :ok <- validate_existing_fields(operation, "transfer_deposit"),
         {:ok, source_group_id} <- required_identifier(operation, "source_group_id"),
         {:ok, destination_group_id} <- required_identifier(operation, "destination_group_id") do
      case Repo.get_by(Group, group_id: source_group_id) do
        nil ->
          rejection(operation, "group_not_found", %{"group_id" => source_group_id})

        source_group ->
          case Repo.get_by(Group, group_id: destination_group_id) do
            nil ->
              rejection(operation, "group_not_found", %{"group_id" => destination_group_id})

            destination_group ->
              apply_transfer_to_groups(operation, source_group, destination_group)
          end
      end
    else
      {:error, code} -> rejection(operation, code)
    end
  end

  defp apply_transfer_to_groups(operation, source_group, destination_group) do
    with :ok <- stale_revision(operation, source_group),
         :ok <- stale_revision(operation, destination_group, "destination_expected_revision"),
         {:ok, _occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- validate_transfer(operation, source_group, destination_group) do
      case prepare_transfer_groups(operation, source_group, destination_group) do
        {:ok, {source_group, destination_group}} ->
          fragments =
            move_funding_allocations(
              source_group.id,
              destination_group.id,
              operation["amount_cents"]
            )

          mark_transfer_participation(fragments)

          source_group = update_group_revision(source_group, source_group.revision + 1)

          destination_group =
            update_group_revision(destination_group, destination_group.revision + 1)

          %{
            "operation_id" => operation["operation_id"],
            "status" => "applied",
            "source_group_id" => source_group.group_id,
            "destination_group_id" => destination_group.group_id,
            "amount_cents" => operation["amount_cents"],
            "source_outstanding_deposit_cents" => outstanding_deposit(source_group),
            "destination_outstanding_deposit_cents" => outstanding_deposit(destination_group),
            "source_revision" => source_group.revision,
            "destination_revision" => destination_group.revision
          }

        {:error, {:transfer_rejected, code}} ->
          rejection(operation, code)
      end
    else
      {:error, result} when is_map(result) -> result
      {:error, {code, extra}} -> rejection(operation, code, extra)
      {:error, code} -> rejection(operation, code)
    end
  end

  defp prepare_transfer_groups(operation, source_group, destination_group) do
    case Repo.transaction(fn ->
           ensure_group_accounting(source_group)
           ensure_group_accounting(destination_group)

           source_group = Repo.get!(Group, source_group.id)
           destination_group = Repo.get!(Group, destination_group.id)

           case validate_transfer_allocations(operation, source_group, destination_group) do
             :ok -> {source_group, destination_group}
             {:error, code} -> Repo.rollback({:transfer_rejected, code})
           end
         end) do
      {:ok, groups} -> {:ok, groups}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_transfer(operation, source_group, destination_group) do
    cond do
      source_group.group_id == destination_group.group_id or
          source_group.guest_id != destination_group.guest_id ->
        {:error, "invalid_transfer"}

      source_group.status != "active" ->
        {:error, {"group_not_active", %{"group_id" => source_group.group_id}}}

      destination_group.status != "active" ->
        {:error, {"group_not_active", %{"group_id" => destination_group.group_id}}}

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        {:error, "invalid_amount"}

      operation["amount_cents"] > aggregate_paid(source_group) ->
        {:error, "transfer_exceeds_held_funding"}

      operation["amount_cents"] > aggregate_outstanding(destination_group) ->
        {:error, "transfer_exceeds_outstanding"}

      true ->
        :ok
    end
  end

  defp validate_transfer_allocations(operation, source_group, destination_group) do
    amount = operation["amount_cents"]

    cond do
      amount > held_funding(source_group.id) -> {:error, "transfer_exceeds_held_funding"}
      amount > outstanding_deposit(destination_group) -> {:error, "transfer_exceeds_outstanding"}
      true -> :ok
    end
  end

  defp aggregate_paid(group), do: max(group.deposit_paid_cents || 0, 0)

  defp held_funding(group_id) do
    cash =
      Repo.one(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: allocation.group_id == ^group_id and room.status == "active",
          select: sum(allocation.amount_cents)
      ) || 0

    credit =
      Repo.one(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: allocation.group_id == ^group_id and room.status == "active",
          select: sum(allocation.amount_cents)
      ) || 0

    cash + credit
  end

  defp move_funding_allocations(source_group_id, destination_group_id, amount) do
    {remaining, fragments} =
      source_group_id
      |> funding_allocations()
      |> Enum.reduce_while({amount, []}, fn allocation, {remaining, fragments} ->
        moved = min(remaining, allocation.amount_cents)
        move_source_allocation(allocation, moved)

        fragment = %{allocation | amount_cents: moved}

        if moved == remaining do
          {:halt, {0, [fragment | fragments]}}
        else
          {:cont, {remaining - moved, [fragment | fragments]}}
        end
      end)

    if remaining != 0, do: raise(ArgumentError, "transfer exceeds held funding")

    fragments = Enum.reverse(fragments)
    fill_destination_rooms(destination_group_id, fragments)
    fragments
  end

  defp funding_allocations(group_id) do
    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and room.status == "active" and
              allocation.amount_cents > 0,
          select: allocation
      )
      |> Enum.map(fn allocation ->
        %{
          kind: :cash,
          id: allocation.id,
          allocation: allocation,
          amount_cents: allocation.amount_cents
        }
      end)

    credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and room.status == "active" and
              allocation.amount_cents > 0,
          select: allocation
      )
      |> Enum.map(fn allocation ->
        %{
          kind: :credit,
          id: allocation.id,
          allocation: allocation,
          amount_cents: allocation.amount_cents
        }
      end)

    (cash_allocations ++ credit_allocations)
    |> Enum.sort_by(
      fn %{kind: kind, id: id, allocation: allocation} ->
        {allocation.allocation_order || 0, if(kind == :cash, do: 0, else: 1), id}
      end,
      :desc
    )
  end

  defp move_source_allocation(%{kind: :cash, allocation: allocation}, amount) do
    room = Repo.get!(Room, allocation.room_id)

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      Repo.update!(
        Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - amount)
      )
    end

    Repo.update!(Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents - amount))
    adjust_payment_property_held(allocation.payment_operation_id, allocation.group_id, -amount)
  end

  defp move_source_allocation(%{kind: :credit, allocation: allocation}, amount) do
    room = Repo.get!(Room, allocation.room_id)

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      Repo.update!(
        Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - amount)
      )
    end

    Repo.update!(Ecto.Changeset.change(room, credit_paid_cents: room.credit_paid_cents - amount))
  end

  defp fill_destination_rooms(group_id, fragments) do
    remaining_fragments =
      Enum.reduce(active_rooms_for(group_id), fragments, fn room, fragments ->
        {_room, fragments} = fill_destination_room(room, fragments)
        fragments
      end)

    if remaining_fragments != [],
      do: raise(ArgumentError, "transfer exceeds destination capacity")

    :ok
  end

  defp fill_destination_room(room, []), do: {room, []}

  defp fill_destination_room(room, fragments) do
    capacity = room_capacity(room)

    if capacity == 0 do
      {room, fragments}
    else
      fill_destination_room(room, fragments, capacity)
    end
  end

  defp fill_destination_room(room, [], _capacity), do: {room, []}
  defp fill_destination_room(room, fragments, 0), do: {room, fragments}

  defp fill_destination_room(room, [fragment | fragments], capacity) do
    moved = min(capacity, fragment.amount_cents)
    allocation_order = next_allocation_order()

    {updated_room, _allocation} =
      case fragment.kind do
        :cash ->
          room =
            Repo.update!(
              Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents + moved)
            )

          allocation =
            Repo.insert!(%CashAllocation{
              group_id: room.group_id,
              room_id: room.id,
              payment_operation_id: fragment.allocation.payment_operation_id,
              amount_cents: moved,
              allocation_order: allocation_order
            })

          adjust_payment_property_held(
            allocation.payment_operation_id,
            room.group_id,
            moved
          )

          {room, allocation}

        :credit ->
          room =
            Repo.update!(
              Ecto.Changeset.change(room, credit_paid_cents: room.credit_paid_cents + moved)
            )

          allocation =
            Repo.insert!(%CreditAllocation{
              group_id: room.group_id,
              room_id: room.id,
              credit_lot_id: fragment.allocation.credit_lot_id,
              funding_operation_id: fragment.allocation.funding_operation_id,
              amount_cents: moved,
              allocation_order: allocation_order
            })

          {room, allocation}
      end

    remaining_fragments =
      if moved == fragment.amount_cents do
        fragments
      else
        [%{fragment | amount_cents: fragment.amount_cents - moved} | fragments]
      end

    fill_destination_room(updated_room, remaining_fragments, capacity - moved)
  end

  defp mark_transfer_participation(fragments) do
    fragments
    |> Enum.filter(&(&1.kind == :cash))
    |> Enum.map(& &1.allocation.payment_operation_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn payment_operation_id ->
      case Repo.get_by(PaymentAccounting, payment_operation_id: payment_operation_id) do
        nil -> :ok
        accounting -> Repo.update!(Ecto.Changeset.change(accounting, transfer_participated: true))
      end
    end)
  end

  defp apply_existing(operation, type, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        rejection(operation, "group_not_found", %{"group_id" => group_id})

      group ->
        case stale_revision(operation, group) do
          :ok ->
            case prevalidate_existing(operation, type, group) do
              :ok ->
                ensure_group_accounting(group)
                group = Repo.get!(Group, group.id)
                apply_existing_with_revision(operation, type, group)

              {:error, code} ->
                rejection(operation, code, %{"group_id" => group.group_id})
            end

          {:error, result} ->
            result
        end
    end
  end

  defp apply_existing_with_revision(operation, type, group) do
    with :ok <- validate_existing_fields(operation, type),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      case type do
        "record_cash_payment" -> apply_cash_payment(operation, group)
        "apply_hotel_credit" -> apply_hotel_credit(operation, group, occurred_on)
        "reschedule_group" -> apply_reschedule(operation, group, occurred_on)
        "cancel_group" -> apply_cancellation(operation, group, occurred_on)
        "cancel_rooms" -> apply_room_cancellation(operation, group, occurred_on)
      end
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})
    end
  end

  defp prevalidate_existing(operation, "record_cash_payment", group) do
    with :ok <- validate_existing_fields(operation, "record_cash_payment"),
         {:ok, _occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- active_group(group),
         {:ok, amount} <- usable_payment_amount(operation["amount_cents"]),
         outstanding when amount <= outstanding <- aggregate_outstanding(group) do
      :ok
    else
      {:error, code} -> {:error, code}
      _ -> {:error, "payment_exceeds_outstanding"}
    end
  end

  defp prevalidate_existing(operation, "apply_hotel_credit", group) do
    with :ok <- validate_existing_fields(operation, "apply_hotel_credit"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- active_group(group),
         {:ok, amount} <- usable_payment_amount(operation["amount_cents"]),
         outstanding when amount <= outstanding <- aggregate_outstanding(group),
         lots <- available_credit_lots(group.guest_id, occurred_on),
         {:ok, _allocations} <- allocate_credit(lots, amount) do
      :ok
    else
      {:error, code} -> {:error, code}
      _ -> {:error, "payment_exceeds_outstanding"}
    end
  end

  defp prevalidate_existing(operation, "reschedule_group", group) do
    with :ok <- validate_existing_fields(operation, "reschedule_group"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- active_group(group),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- validate_reschedule_date(new_arrival_on, occurred_on) do
      :ok
    else
      {:error, code} -> {:error, code}
    end
  end

  defp prevalidate_existing(operation, "cancel_group", group) do
    with :ok <- validate_existing_fields(operation, "cancel_group"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- active_group(group),
         {:ok, refund_method} <- cancellation_refund_method(operation) do
      if refundable?(group, occurred_on) or refund_method == "cash",
        do: :ok,
        else: {:error, "refund_method_not_available"}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp prevalidate_existing(operation, "cancel_rooms", group) do
    with :ok <- validate_existing_fields(operation, "cancel_rooms"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- active_group(group),
         {:ok, refund_method} <- cancellation_refund_method(operation),
         {:ok, _rooms} <- selected_rooms(group, operation["room_ids"]) do
      if refundable?(group, occurred_on) or refund_method == "cash",
        do: :ok,
        else: {:error, "refund_method_not_available"}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp aggregate_outstanding(group),
    do: max((group.deposit_due_cents || 0) - (group.deposit_paid_cents || 0), 0)

  defp apply_cash_payment(operation, group) do
    with :ok <- active_group(group),
         {:ok, amount} <- usable_payment_amount(operation["amount_cents"]),
         outstanding when amount <= outstanding <- outstanding_deposit(group) do
      allocate_cash_to_rooms(group, amount, operation["operation_id"])
      new_revision = group.revision + 1

      accounting = %PaymentAccounting{
        payment_operation_id: operation["operation_id"],
        group_id: group.id,
        recorded_cents: amount,
        held_cents: amount,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0,
        transfer_participated: false
      }

      Repo.insert!(accounting)

      Repo.insert!(%PaymentPropertyAccounting{
        payment_operation_id: operation["operation_id"],
        group_id: group.id,
        held_cents: amount,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0
      })

      updated_group = update_group_revision(group, new_revision)

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => new_revision
      }
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})

      _ ->
        rejection(operation, "payment_exceeds_outstanding", %{"group_id" => group.group_id})
    end
  end

  defp apply_hotel_credit(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, amount} <- usable_payment_amount(operation["amount_cents"]),
         outstanding when amount <= outstanding <- outstanding_deposit(group),
         lots <- available_credit_lots(group.guest_id, occurred_on),
         {:ok, allocations} <- allocate_credit(lots, amount) do
      Enum.each(allocations, fn {lot, allocated} ->
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - allocated))
      end)

      allocate_credit_to_rooms(group, allocations, operation["operation_id"])
      new_revision = group.revision + 1
      updated_group = update_group_revision(group, new_revision)

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => new_revision
      }
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})

      _ ->
        rejection(operation, "payment_exceeds_outstanding", %{"group_id" => group.group_id})
    end
  end

  defp apply_reschedule(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- validate_reschedule_date(new_arrival_on, occurred_on) do
      day_shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, day_shift)
      new_revision = group.revision + 1

      Repo.update!(
        Ecto.Changeset.change(group,
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: new_revision
        )
      )

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "group_id" => group.group_id,
        "new_arrival_on" => Date.to_iso8601(new_arrival_on),
        "new_departure_on" => Date.to_iso8601(new_departure_on),
        "revision" => new_revision
      }
      |> Map.merge(policy_fields(%{group | arrival_on: new_arrival_on}))
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})
    end
  end

  defp apply_cancellation(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, refund_method} <- cancellation_refund_method(operation) do
      refundable? = refundable?(group, occurred_on)

      if refundable? or refund_method == "cash" do
        active_rooms = Enum.filter(rooms_for(group.id), &(&1.status == "active"))

        settle_rooms(
          operation,
          group,
          active_rooms,
          occurred_on,
          refund_method,
          refundable?,
          false
        )
      else
        rejection(operation, "refund_method_not_available", %{"group_id" => group.group_id})
      end
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})
    end
  end

  defp apply_room_cancellation(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, refund_method} <- cancellation_refund_method(operation),
         {:ok, rooms} <- selected_rooms(group, operation["room_ids"]) do
      refundable? = refundable?(group, occurred_on)

      if refundable? or refund_method == "cash" do
        settle_rooms(operation, group, rooms, occurred_on, refund_method, refundable?, true)
      else
        rejection(operation, "refund_method_not_available", %{"group_id" => group.group_id})
      end
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})
    end
  end

  defp settle_rooms(operation, group, rooms, occurred_on, refund_method, refundable?, selected?) do
    room_ids = MapSet.new(Enum.map(rooms, & &1.id))

    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          where:
            allocation.group_id == ^group.id and allocation.room_id in ^MapSet.to_list(room_ids),
          order_by: [asc: allocation.allocation_order, asc: allocation.id]
      )

    cash_by_source =
      cash_allocations
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.map(fn {source, allocations} ->
        {source, Enum.sum(Enum.map(allocations, & &1.amount_cents)),
         Enum.min_by(allocations, &{&1.allocation_order || 0, &1.id}).allocation_order || 0}
      end)
      |> sort_funding_sources()

    Enum.each(cash_allocations, fn allocation -> Repo.delete!(allocation) end)

    rooms
    |> Enum.each(fn room ->
      amount =
        cash_allocations
        |> Enum.filter(&(&1.room_id == room.id))
        |> Enum.sum_by(& &1.amount_cents)

      if amount > 0 do
        Repo.update!(
          Ecto.Changeset.change(room, cash_paid_cents: max(room.cash_paid_cents - amount, 0))
        )
      end
    end)

    {ledger_kind, refunded, retained} =
      cond do
        refundable? and refund_method == "hotel_credit" -> {"converted_to_credit", 0, 0}
        refundable? -> {"refunded", Enum.sum(Enum.map(cash_by_source, &elem(&1, 1))), 0}
        true -> {"retained", 0, Enum.sum(Enum.map(cash_by_source, &elem(&1, 1)))}
      end

    Enum.each(cash_by_source, fn {source, amount, _order} ->
      settle_cash_source(source, group, amount, ledger_kind)
    end)

    credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where:
            allocation.group_id == ^group.id and allocation.room_id in ^MapSet.to_list(room_ids),
          order_by: [asc: allocation.id]
      )

    Enum.each(credit_allocations, fn allocation -> Repo.delete!(allocation) end)

    credit_allocations
    |> Enum.group_by(& &1.room_id)
    |> Enum.each(fn {room_id, allocations} ->
      room = Repo.get!(Room, room_id)
      amount = Enum.sum(Enum.map(allocations, & &1.amount_cents))

      Repo.update!(
        Ecto.Changeset.change(room, credit_paid_cents: max(room.credit_paid_cents - amount, 0))
      )
    end)

    if refundable? do
      credit_allocations
      |> Enum.group_by(& &1.credit_lot_id)
      |> Enum.each(fn {lot_id, allocations} ->
        restore_credit_amount(
          Repo.get!(CreditLot, lot_id),
          Enum.sum(Enum.map(allocations, & &1.amount_cents)),
          occurred_on
        )
      end)
    end

    Enum.each(rooms, fn room ->
      Repo.update!(Ecto.Changeset.change(room, status: "cancelled"))
    end)

    credit_issued =
      if refundable? and refund_method == "hotel_credit" do
        issue_credit_lot(
          group,
          operation["operation_id"],
          occurred_on,
          Enum.sum(Enum.map(cash_by_source, &elem(&1, 1))),
          cash_by_source
        )
      else
        0
      end

    new_revision = group.revision + 1

    status =
      if Enum.any?(rooms_for(group.id), &(&1.status == "active")), do: "active", else: "cancelled"

    updated_group =
      group
      |> Ecto.Changeset.change(status: status, revision: new_revision)
      |> Repo.update!()

    refreshed_group = refresh_group_totals(updated_group)

    result = %{
      "operation_id" => operation["operation_id"],
      "status" => "applied",
      "group_id" => group.group_id,
      "refunded_cents" => refunded,
      "retained_cents" => retained,
      "credit_issued_cents" => credit_issued,
      "revision" => new_revision
    }

    if selected? do
      Map.put(result, "cancelled_room_ids", room_ids_in_original_order(group.id, rooms))
    else
      result
    end
    |> Map.put("revision", refreshed_group.revision)
  end

  defp settle_cash_source(nil, group, amount, kind) do
    if amount > 0 do
      Repo.insert!(%LedgerEntry{group_id: group.id, kind: kind, amount_cents: amount})
    end
  end

  defp settle_cash_source(source, group, amount, kind) do
    if amount > 0 do
      accounting = Repo.get_by!(PaymentAccounting, payment_operation_id: source)

      Repo.update!(
        Ecto.Changeset.change(accounting,
          held_cents: accounting.held_cents - amount,
          refunded_cents: accounting.refunded_cents + if(kind == "refunded", do: amount, else: 0),
          retained_cents: accounting.retained_cents + if(kind == "retained", do: amount, else: 0),
          converted_to_credit_cents:
            accounting.converted_to_credit_cents +
              if(kind == "converted_to_credit", do: amount, else: 0)
        )
      )

      adjust_payment_property_disposition(source, group.id, kind, amount)
    end
  end

  defp apply_payment_operation(operation, type) do
    with {:ok, payment_operation_id} <- required_identifier(operation, "payment_operation_id") do
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil ->
          rejection(operation, "operation_not_found")

        record ->
          apply_payment_operation_to_record(operation, type, payment_operation_id, record)
      end
    else
      {:error, code} -> rejection(operation, code)
    end
  end

  defp apply_payment_operation_to_record(operation, type, payment_operation_id, record) do
    case result_group_id(record) do
      {:ok, group_id} ->
        case Repo.get_by(Group, group_id: group_id) do
          nil ->
            rejection(operation, target_error(type, record))

          group ->
            case stale_revision(operation, group) do
              {:error, result} ->
                result

              :ok ->
                with :ok <- validate_existing_fields(operation, type),
                     {:ok, _occurred_on} <- parse_date(operation["occurred_on"]) do
                  case prevalidate_payment_target(operation, type, record, group) do
                    :ok ->
                      ensure_group_accounting(group)
                      group = Repo.get!(Group, group.id)

                      with {:ok, accounting} <-
                             payment_for_operation(record, payment_operation_id, type) do
                        case type do
                          "reduce_cash_payment" ->
                            reduce_cash_payment(operation, group, accounting)

                          "charge_back_payment" ->
                            charge_back_payment(operation, group, accounting)
                        end
                      else
                        {:error, code} -> rejection(operation, code, target_group_extra(group))
                      end

                    {:error, code} ->
                      rejection(operation, code, target_group_extra(group))
                  end
                else
                  {:error, code} -> rejection(operation, code, target_group_extra(group))
                end
            end
        end

      {:error, _code} ->
        rejection(operation, target_error(type, record))
    end
  end

  defp result_group_id(%OperationRecord{result: %{"group_id" => group_id}})
       when is_binary(group_id) and byte_size(group_id) > 0,
       do: {:ok, group_id}

  defp result_group_id(_record), do: {:error, "operation_not_found"}

  defp reducible_payment(
         %OperationRecord{type: "record_cash_payment", result: %{"status" => "applied"}},
         id
       ) do
    case Repo.get_by(PaymentAccounting, payment_operation_id: id) do
      nil -> {:error, "payment_not_reducible"}
      accounting when accounting.held_cents > 0 -> {:ok, accounting}
      _accounting -> {:error, "payment_not_reducible"}
    end
  end

  defp reducible_payment(_record, _id), do: {:error, "payment_not_reducible"}

  defp payment_for_operation(record, id, "reduce_cash_payment"),
    do: reducible_payment(record, id)

  defp payment_for_operation(record, id, "charge_back_payment") do
    case record do
      %OperationRecord{type: "record_cash_payment", result: %{"status" => "applied"}} ->
        case Repo.get_by(PaymentAccounting, payment_operation_id: id) do
          nil ->
            {:error, "payment_not_chargeable"}

          accounting ->
            if accounting.charged_back_cents > 0 or
                 accounting.recorded_cents == accounting.reduced_cents do
              {:error, "payment_not_chargeable"}
            else
              {:ok, accounting}
            end
        end

      _ ->
        {:error, "payment_not_chargeable"}
    end
  end

  defp target_error("reduce_cash_payment", _record), do: "payment_not_reducible"
  defp target_error("charge_back_payment", _record), do: "payment_not_chargeable"

  defp prevalidate_payment_target(operation, "reduce_cash_payment", record, _group) do
    cond do
      not applied_cash_payment?(record) ->
        {:error, "payment_not_reducible"}

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        {:error, "invalid_amount"}

      true ->
        case Repo.get_by(PaymentAccounting, payment_operation_id: record.operation_id) do
          %PaymentAccounting{held_cents: held_cents} when held_cents <= 0 ->
            {:error, "payment_not_reducible"}

          _ ->
            if operation["amount_cents"] > (record.result["amount_cents"] || 0),
              do: {:error, "reduction_exceeds_held_cash"},
              else: :ok
        end
    end
  end

  defp prevalidate_payment_target(_operation, "charge_back_payment", record, _group) do
    if applied_cash_payment?(record), do: :ok, else: {:error, "payment_not_chargeable"}
  end

  defp applied_cash_payment?(%OperationRecord{
         type: "record_cash_payment",
         result: %{"status" => "applied"}
       }),
       do: true

  defp applied_cash_payment?(_record), do: false

  defp reduce_cash_payment(operation, group, accounting) do
    amount = operation["amount_cents"]

    cond do
      not (is_integer(amount) and amount > 0) ->
        rejection(operation, "invalid_amount", target_group_extra(group))

      amount > accounting.held_cents ->
        rejection(operation, "reduction_exceeds_held_cash", target_group_extra(group))

      true ->
        affected_group_ids =
          remove_cash_for_payment(accounting.payment_operation_id, amount, "reduced")

        Repo.update!(
          Ecto.Changeset.change(accounting,
            held_cents: accounting.held_cents - amount,
            reduced_cents: accounting.reduced_cents + amount
          )
        )

        updated_groups = bump_group_revisions(affected_group_ids, group.id)
        updated_group = Map.fetch!(updated_groups, group.id)

        %{
          "operation_id" => operation["operation_id"],
          "status" => "applied",
          "payment_operation_id" => accounting.payment_operation_id,
          "group_id" => group.group_id,
          "amount_cents" => amount,
          "outstanding_deposit_cents" => outstanding_deposit(updated_group),
          "revision" => updated_group.revision
        }
    end
  end

  defp charge_back_payment(operation, group, accounting) do
    amount =
      accounting.held_cents + accounting.refunded_cents + accounting.retained_cents +
        accounting.converted_to_credit_cents

    if amount <= 0 or accounting.charged_back_cents > 0 or
         accounting.recorded_cents == accounting.reduced_cents do
      rejection(operation, "payment_not_chargeable", target_group_extra(group))
    else
      affected_group_ids =
        remove_cash_for_payment(accounting.payment_operation_id, accounting.held_cents, nil)

      revoke_credit_entitlement(accounting.payment_operation_id)
      charge_back_property_dispositions(accounting.payment_operation_id)

      Repo.update!(
        Ecto.Changeset.change(accounting,
          held_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: accounting.charged_back_cents + amount
        )
      )

      updated_groups = bump_group_revisions(affected_group_ids, group.id)
      updated_group = Map.fetch!(updated_groups, group.id)

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "payment_operation_id" => accounting.payment_operation_id,
        "group_id" => group.group_id,
        "charged_back_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      }
    end
  end

  defp remove_cash_for_payment(_payment_operation_id, 0, _disposition), do: MapSet.new()

  defp remove_cash_for_payment(payment_operation_id, amount, disposition) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          join: group in Group,
          on: group.id == allocation.group_id,
          where:
            allocation.payment_operation_id == ^payment_operation_id and
              room.status == "active" and group.status == "active",
          order_by: [desc: allocation.allocation_order, desc: allocation.id]
      )

    {remaining, affected_group_ids} =
      Enum.reduce_while(allocations, {amount, MapSet.new()}, fn allocation,
                                                                {remaining, affected_group_ids} ->
        removed = min(remaining, allocation.amount_cents)
        room = Repo.get!(Room, allocation.room_id)

        if removed == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update!(
            Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - removed)
          )
        end

        Repo.update!(Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents - removed))

        if disposition do
          adjust_payment_property_disposition(
            payment_operation_id,
            allocation.group_id,
            disposition,
            removed
          )
        else
          adjust_payment_property_held(payment_operation_id, allocation.group_id, -removed)
        end

        affected_group_ids = MapSet.put(affected_group_ids, allocation.group_id)

        if removed == remaining do
          {:halt, {0, affected_group_ids}}
        else
          {:cont, {remaining - removed, affected_group_ids}}
        end
      end)

    if remaining != 0, do: raise(ArgumentError, "payment allocation coverage is inconsistent")

    affected_group_ids
  end

  defp revoke_credit_entitlement(payment_operation_id) do
    Repo.all(
      from contribution in CreditLotContribution,
        where: contribution.payment_operation_id == ^payment_operation_id,
        order_by: [asc: contribution.id]
    )
    |> Enum.each(fn contribution ->
      lot = Repo.get!(CreditLot, contribution.credit_lot_id)
      available = min(lot.remaining_cents, contribution.entitlement_cents)
      unrecovered = contribution.entitlement_cents - available

      Repo.update!(
        Ecto.Changeset.change(lot,
          remaining_cents: lot.remaining_cents - available,
          unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + unrecovered
        )
      )
    end)
  end

  defp stale_revision(operation, group),
    do: stale_revision(operation, group, "expected_revision")

  defp stale_revision(operation, group, field) do
    case Map.fetch(operation, field) do
      :error ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:error,
         rejection(operation, "stale_revision", %{
           "group_id" => group.group_id,
           "expected_revision" => expected_revision,
           "actual_revision" => group.revision
         })}
    end
  end

  defp validate_common_fields(operation) do
    if valid_identifier(operation["operation_id"]) and is_binary(operation["occurred_on"]) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_existing_fields(operation, "record_cash_payment") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "amount_cents") do
      :ok
    end
  end

  defp validate_existing_fields(operation, "reschedule_group") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "new_arrival_on") do
      :ok
    end
  end

  defp validate_existing_fields(operation, "apply_hotel_credit") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "amount_cents") do
      :ok
    end
  end

  defp validate_existing_fields(operation, "cancel_group") do
    with :ok <- validate_common_fields(operation),
         :ok <- validate_refund_method(operation) do
      :ok
    end
  end

  defp validate_existing_fields(operation, "cancel_rooms") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "room_ids"),
         :ok <- validate_refund_method(operation) do
      :ok
    end
  end

  defp validate_existing_fields(operation, "transfer_deposit") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "amount_cents") do
      :ok
    end
  end

  defp validate_existing_fields(operation, type)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    with :ok <- validate_common_fields(operation),
         :ok <-
           if(type == "reduce_cash_payment",
             do: require_field(operation, "amount_cents"),
             else: :ok
           ) do
      :ok
    end
  end

  defp require_field(operation, field) do
    if Map.has_key?(operation, field), do: :ok, else: {:error, "invalid_operation"}
  end

  defp validate_refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> :ok
      {:ok, method} when method in ["cash", "hotel_credit"] -> :ok
      _ -> {:error, "invalid_operation"}
    end
  end

  defp cancellation_refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(operation, field) do
    if valid_identifier(operation[field]) do
      {:ok, operation[field]}
    else
      {:error, "invalid_operation"}
    end
  end

  defp valid_identifier(value), do: is_binary(value) and byte_size(value) > 0

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_stay"}

  defp reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_reporting_date"}
    end
  end

  defp reporting_date(_value), do: {:error, "invalid_reporting_date"}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(arrival_on, departure_on) == :lt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_reschedule_date(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"],
    do: {:ok, rate_plan}

  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms, arrival_on, departure_on, rate_plan) when is_list(rooms) do
    if rooms == [] do
      {:error, "invalid_rooms"}
    else
      nights = Date.diff(departure_on, arrival_on)

      rooms
      |> Enum.with_index()
      |> Enum.reduce_while({[], 0, MapSet.new()}, fn {room, position},
                                                     {valid_rooms, lodging_total, room_ids} ->
        with {:ok, room_id} <- room_identifier(room),
             false <- MapSet.member?(room_ids, room_id),
             {:ok, nightly_rate_cents} <- nightly_rate(room) do
          lodging = nights * nightly_rate_cents
          deposit = deposit_for(lodging, rate_plan)

          {:cont,
           {[{room_id, nightly_rate_cents, position, deposit} | valid_rooms],
            lodging_total + lodging, MapSet.put(room_ids, room_id)}}
        else
          true -> {:halt, {:error, "invalid_rooms"}}
          {:error, _reason} -> {:halt, {:error, "invalid_rooms"}}
        end
      end)
      |> case do
        {valid_rooms, lodging_total, _room_ids} ->
          rooms =
            valid_rooms
            |> Enum.reverse()
            |> Enum.map(fn {room_id, nightly_rate_cents, position, deposit_due_cents} ->
              %{
                room_id: room_id,
                nightly_rate_cents: nightly_rate_cents,
                position: position,
                deposit_due_cents: deposit_due_cents
              }
            end)

          deposit_due =
            Enum.sum(Enum.map(valid_rooms, fn {_id, _rate, _position, deposit} -> deposit end))

          {:ok, rooms, lodging_total, deposit_due}

        {:error, code} ->
          {:error, code}
      end
    end
  end

  defp validate_rooms(_rooms, _arrival_on, _departure_on, _rate_plan),
    do: {:error, "invalid_rooms"}

  defp room_identifier(room) when is_map(room), do: required_identifier(room, "room_id")
  defp room_identifier(_room), do: {:error, "invalid_rooms"}

  defp nightly_rate(room) when is_map(room) do
    case room["nightly_rate_cents"] do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp deposit_for(lodging, "advance_purchase"), do: lodging
  defp deposit_for(lodging, "flexible"), do: div(lodging * 20 + 50, 100)

  defp active_group(%Group{status: "active"}), do: :ok
  defp active_group(_group), do: {:error, "group_not_active"}

  defp usable_payment_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp usable_payment_amount(_amount), do: {:error, "invalid_amount"}

  defp available_credit_lots(guest_id, occurred_on) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on > ^occurred_on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp allocate_credit(lots, amount) do
    {remaining, allocations} =
      Enum.reduce_while(lots, {amount, []}, fn lot, {remaining, allocations} ->
        allocated = min(remaining, lot.remaining_cents)

        if allocated == remaining do
          {:halt, {0, [{lot, allocated} | allocations]}}
        else
          {:cont, {remaining - allocated, [{lot, allocated} | allocations]}}
        end
      end)

    if remaining == 0 do
      {:ok, Enum.reverse(allocations)}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp allocate_cash_to_rooms(group, amount, payment_operation_id) do
    {remaining, _rooms} =
      Enum.reduce_while(active_rooms_for(group.id), {amount, :ok}, fn room, {remaining, :ok} ->
        capacity = room_capacity(room)
        allocated = min(remaining, capacity)

        if allocated > 0 do
          Repo.update!(
            Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents + allocated)
          )

          Repo.insert!(%CashAllocation{
            group_id: group.id,
            room_id: room.id,
            payment_operation_id: payment_operation_id,
            amount_cents: allocated,
            allocation_order: next_allocation_order()
          })
        end

        if allocated == remaining do
          {:halt, {0, :ok}}
        else
          {:cont, {remaining - allocated, :ok}}
        end
      end)

    if remaining != 0, do: raise(ArgumentError, "funding exceeds room capacity")
    :ok
  end

  defp allocate_credit_to_rooms(group, allocations, funding_operation_id) do
    Enum.reduce(allocations, :ok, fn {lot, amount}, :ok ->
      {remaining, _} =
        Enum.reduce_while(active_rooms_for(group.id), {amount, :ok}, fn room, {remaining, :ok} ->
          capacity = room_capacity(room)
          allocated = min(remaining, capacity)

          if allocated > 0 do
            Repo.update!(
              Ecto.Changeset.change(room, credit_paid_cents: room.credit_paid_cents + allocated)
            )

            Repo.insert!(%CreditAllocation{
              group_id: group.id,
              room_id: room.id,
              credit_lot_id: lot.id,
              funding_operation_id: funding_operation_id,
              amount_cents: allocated,
              allocation_order: next_allocation_order()
            })
          end

          if allocated == remaining do
            {:halt, {0, :ok}}
          else
            {:cont, {remaining - allocated, :ok}}
          end
        end)

      if remaining != 0, do: raise(ArgumentError, "credit exceeds room capacity")
      :ok
    end)
  end

  defp selected_rooms(group, room_ids) when is_list(room_ids) do
    if room_ids == [] or Enum.any?(room_ids, &(not valid_identifier(&1))) or
         MapSet.size(MapSet.new(room_ids)) != length(room_ids) do
      {:error, "invalid_rooms"}
    else
      rooms = rooms_for(group.id)

      selected =
        Enum.filter(rooms, fn room -> room.room_id in room_ids and room.status == "active" end)

      if length(selected) == length(room_ids) do
        {:ok, selected}
      else
        {:error, "invalid_rooms"}
      end
    end
  end

  defp selected_rooms(_group, _room_ids), do: {:error, "invalid_rooms"}

  defp room_ids_in_original_order(_group_id, rooms), do: Enum.map(rooms, & &1.room_id)

  defp restore_credit_amount(lot, amount, occurred_on) do
    absorbed = min(amount, lot.unrecovered_clawback_cents || 0)
    excess = amount - absorbed

    remaining =
      if excess > 0 and Date.compare(lot.expires_on, occurred_on) == :gt do
        lot.remaining_cents + excess
      else
        lot.remaining_cents
      end

    Repo.update!(
      Ecto.Changeset.change(lot,
        remaining_cents: remaining,
        unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) - absorbed
      )
    )
  end

  defp issue_credit_lot(_group, _source_operation_id, _occurred_on, 0, _sources), do: 0

  defp issue_credit_lot(group, source_operation_id, occurred_on, cash_paid, sources) do
    credit_issued = credit_value(cash_paid)

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: credit_issued,
        expires_on: Date.add(occurred_on, 366),
        unrecovered_clawback_cents: 0
      })

    sources
    |> sort_funding_sources()
    |> Enum.reduce({0, 0}, fn {payment_operation_id, principal, _order},
                              {prior_cash, prior_value} ->
      current_cash = prior_cash + principal
      current_value = credit_value(current_cash)
      entitlement = current_value - prior_value

      if principal > 0 do
        Repo.insert!(%CreditLotContribution{
          credit_lot_id: lot.id,
          payment_operation_id: payment_operation_id,
          principal_cents: principal,
          entitlement_cents: entitlement
        })
      end

      {current_cash, current_value}
    end)

    credit_issued
  end

  defp credit_value(cash), do: cash + div(cash * 10 + 50, 100)

  defp sort_funding_sources(sources) do
    records =
      Repo.all(from record in OperationRecord, select: {record.operation_id, record.id})
      |> Map.new()

    sources
    |> Enum.map(fn
      {source, amount, order} -> {source, amount, order}
      {source, amount} -> {source, amount, nil}
    end)
    |> Enum.sort_by(fn {source, _amount, order} ->
      case source do
        nil ->
          {0, 0, ""}

        _ ->
          source_order =
            if is_integer(order) and order > 0,
              do: order,
              else: Map.get(records, source, 1_000_000_000)

          {1, source_order, source}
      end
    end)
  end

  defp rooms_for(group_id) do
    Repo.all(from room in Room, where: room.group_id == ^group_id, order_by: [asc: room.position])
  end

  defp active_rooms_for(group_id), do: Enum.filter(rooms_for(group_id), &(&1.status == "active"))

  defp next_allocation_order, do: Repo.insert!(%AllocationOrder{}).id

  defp room_capacity(%Room{status: "active"} = room),
    do: max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)

  defp room_capacity(_room), do: 0

  defp refresh_group_totals(group) do
    rooms = Enum.filter(rooms_for(group.id), &(&1.status == "active"))
    lodging_total = Enum.sum(Enum.map(rooms, &room_lodging(&1, group)))
    deposit_due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))
    cash_paid = Enum.sum(Enum.map(rooms, & &1.cash_paid_cents))
    credit_paid = Enum.sum(Enum.map(rooms, & &1.credit_paid_cents))

    attrs = [
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      deposit_paid_cents: cash_paid + credit_paid,
      cash_paid_cents: cash_paid,
      credit_paid_cents: credit_paid
    ]

    Repo.update!(Ecto.Changeset.change(group, attrs))
  end

  defp room_lodging(room, group),
    do: Date.diff(group.departure_on, group.arrival_on) * room.nightly_rate_cents

  defp outstanding_deposit(group) do
    rooms = Enum.filter(rooms_for(group.id), &(&1.status == "active"))
    Enum.sum(Enum.map(rooms, &room_capacity/1))
  end

  defp update_group_revision(group, revision) do
    group = refresh_group_totals(group)
    Repo.update!(Ecto.Changeset.change(group, revision: revision))
  end

  defp bump_group_revisions(affected_group_ids, addressed_group_id) do
    affected_group_ids
    |> MapSet.put(addressed_group_id)
    |> Enum.map(fn group_id ->
      group = Repo.get!(Group, group_id)
      updated_group = update_group_revision(group, group.revision + 1)
      {group_id, updated_group}
    end)
    |> Map.new()
  end

  defp target_group_extra(group), do: %{"group_id" => group.group_id}

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^as_of,
          select: sum(lot.remaining_cents)
      ) || 0

    applied =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          where: group.status == "active",
          select: sum(allocation.amount_cents)
      ) || 0

    available + applied
  end

  defp credit_shortfall do
    Repo.all(
      from lot in CreditLot,
        join: allocation in CreditAllocation,
        on: allocation.credit_lot_id == lot.id,
        join: group in Group,
        on: group.id == allocation.group_id,
        where: group.status == "active",
        group_by: [lot.id, lot.unrecovered_clawback_cents],
        select: {lot.unrecovered_clawback_cents, sum(allocation.amount_cents)}
    )
    |> Enum.map(fn {unrecovered, applied} -> min(unrecovered || 0, applied || 0) end)
    |> Enum.sum()
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_details(group) do
    case group.policy_version do
      "flex-14" ->
        {"flex-14", 14}

      "flex-30" ->
        {"flex-30", 30}

      "advance-nonrefundable" ->
        {"advance-nonrefundable", nil}

      _ ->
        case policy_version(group.rate_plan, group.booked_on) do
          "advance-nonrefundable" -> {"advance-nonrefundable", nil}
          version -> {version, if(version == "flex-14", do: 14, else: 30)}
        end
    end
  end

  defp policy_fields(group) do
    {version, window} = policy_details(group)

    %{
      "policy_version" => version,
      "refundable_until" =>
        if(window, do: Date.to_iso8601(Date.add(group.arrival_on, -window)), else: nil)
    }
  end

  defp refundable?(group, occurred_on) do
    {_version, window} = policy_details(group)
    is_integer(window) and Date.diff(group.arrival_on, occurred_on) >= window
  end

  defp render_group(group, rooms) do
    active_rooms = Enum.filter(rooms, &(&1.status == "active"))

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "revision" => group.revision,
      "rooms" =>
        Enum.map(rooms, fn room ->
          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents,
            "lodging_total_cents" => room_lodging(room, group),
            "status" => room.status,
            "deposit_due_cents" => room.deposit_due_cents,
            "cash_paid_cents" => if(room.status == "active", do: room.cash_paid_cents, else: 0),
            "credit_paid_cents" =>
              if(room.status == "active", do: room.credit_paid_cents, else: 0)
          }
        end),
      "lodging_total_cents" => Enum.sum(Enum.map(active_rooms, &room_lodging(&1, group))),
      "deposit_due_cents" => Enum.sum(Enum.map(active_rooms, & &1.deposit_due_cents)),
      "deposit_paid_cents" =>
        Enum.sum(Enum.map(active_rooms, &(&1.cash_paid_cents + &1.credit_paid_cents))),
      "cash_paid_cents" => Enum.sum(Enum.map(active_rooms, & &1.cash_paid_cents)),
      "credit_paid_cents" => Enum.sum(Enum.map(active_rooms, & &1.credit_paid_cents)),
      "outstanding_deposit_cents" => Enum.sum(Enum.map(active_rooms, &room_capacity/1))
    }
    |> Map.merge(policy_fields(group))
  end

  defp ensure_group_accounting(group) do
    records = durable_funding_records(group.group_id)
    durable_cash = Enum.filter(records, &(&1.type == "record_cash_payment"))
    backfilled_dispositions = backfilled_dispositions(group, durable_cash)

    Enum.each(records, fn record ->
      if record.type == "record_cash_payment" do
        amount = record.result["amount_cents"] || 0

        unless Repo.get_by(PaymentAccounting, payment_operation_id: record.operation_id) do
          disposition = Map.get(backfilled_dispositions, record.operation_id, %{})

          Repo.insert!(%PaymentAccounting{
            payment_operation_id: record.operation_id,
            group_id: group.id,
            backfilled: true,
            recorded_cents: amount,
            held_cents:
              Map.get(disposition, :held, if(group.status == "active", do: amount, else: 0)),
            refunded_cents: Map.get(disposition, :refunded, 0),
            retained_cents: Map.get(disposition, :retained, 0),
            converted_to_credit_cents: Map.get(disposition, :converted_to_credit, 0),
            backfilled_refunded_cents: Map.get(disposition, :refunded, 0),
            backfilled_retained_cents: Map.get(disposition, :retained, 0),
            backfilled_converted_to_credit_cents: Map.get(disposition, :converted_to_credit, 0),
            reduced_cents: 0,
            charged_back_cents: 0,
            transfer_participated: false
          })
        end
      end
    end)

    durable_credit = Enum.filter(records, &(&1.type == "apply_hotel_credit"))
    group_cash = group.cash_paid_cents || group.deposit_paid_cents || 0
    group_credit = group.credit_paid_cents || 0
    durable_cash_total = Enum.sum(Enum.map(durable_cash, &(&1.result["amount_cents"] || 0)))
    durable_credit_total = Enum.sum(Enum.map(durable_credit, &(&1.result["amount_cents"] || 0)))
    legacy_cash = max(group_cash - durable_cash_total, 0)
    legacy_credit = max(group_credit - durable_credit_total, 0)

    existing_credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.id and is_nil(allocation.room_id),
          order_by: [asc: allocation.id]
      )

    credit_fragments =
      if group.status != "active" or existing_credit_allocations == [] do
        []
      else
        categories =
          ([{nil, legacy_credit}] ++
             Enum.map(durable_credit, fn record ->
               {record.operation_id, record.result["amount_cents"] || 0}
             end))
          |> Enum.filter(fn {_source, amount} -> amount > 0 end)

        prepare_existing_credit_fragments(existing_credit_allocations, categories)
      end

    if group.status == "active" and legacy_cash > 0 and not cash_allocated?(group.id) do
      allocate_cash_to_rooms(group, legacy_cash, nil)
    end

    {legacy_fragments, durable_fragments} = Enum.split_while(credit_fragments, &is_nil(&1.source))
    allocate_credit_fragments(group, legacy_fragments)

    Enum.reduce(records, durable_fragments, fn record, remaining_fragments ->
      case record.type do
        "record_cash_payment" ->
          accounting = Repo.get_by!(PaymentAccounting, payment_operation_id: record.operation_id)

          if accounting.held_cents > 0 and not payment_allocated?(record.operation_id) do
            allocate_cash_to_rooms(group, accounting.held_cents, record.operation_id)
          end

          remaining_fragments

        "apply_hotel_credit" ->
          {fragments, rest} =
            Enum.split_while(remaining_fragments, &(&1.source == record.operation_id))

          allocate_credit_fragments(group, fragments)
          rest
      end
    end)

    backfill_credit_contributions(group, durable_cash)

    :ok
  end

  defp durable_funding_records(group_id) do
    Repo.all(from record in OperationRecord, order_by: [asc: record.id])
    |> Enum.filter(fn record ->
      record.result["group_id"] == group_id and
        record.result["status"] == "applied" and
        record.type in ["record_cash_payment", "apply_hotel_credit"]
    end)
  end

  defp backfilled_dispositions(%Group{status: "active"}, durable_cash) do
    Map.new(durable_cash, fn record ->
      {record.operation_id, %{held: record.result["amount_cents"] || 0}}
    end)
  end

  defp backfilled_dispositions(group, durable_cash) do
    totals =
      Repo.all(
        from entry in LedgerEntry,
          where: entry.group_id == ^group.id,
          group_by: entry.kind,
          select: {entry.kind, sum(entry.amount_cents)}
      )
      |> Map.new(fn {kind, amount} -> {kind, amount || 0} end)

    durable_total = Enum.sum(Enum.map(durable_cash, &(&1.result["amount_cents"] || 0)))
    legacy_cash = max(Map.get(totals, "held", 0) - durable_total, 0)
    {_legacy_assignment, remaining} = consume_dispositions(totals, legacy_cash)

    {assignments, _remaining} =
      Enum.reduce(durable_cash, {%{}, remaining}, fn record, {assignments, remaining} ->
        amount = record.result["amount_cents"] || 0
        {assignment, next_remaining} = consume_dispositions(remaining, amount)
        {Map.put(assignments, record.operation_id, assignment), next_remaining}
      end)

    assignments
  end

  defp consume_dispositions(totals, amount) do
    Enum.reduce(@disposition_kinds, {%{}, totals, amount}, fn kind,
                                                              {assignment, totals, remaining} ->
      taken = min(remaining, Map.get(totals, kind, 0))

      {
        Map.put(assignment, disposition_field(kind), taken),
        Map.put(totals, kind, Map.get(totals, kind, 0) - taken),
        remaining - taken
      }
    end)
    |> then(fn {assignment, totals, _remaining} -> {assignment, totals} end)
  end

  defp disposition_field("converted_to_credit"), do: :converted_to_credit
  defp disposition_field(kind), do: String.to_atom(kind)

  defp backfill_credit_contributions(%Group{status: "active"}, _durable_cash), do: :ok

  defp backfill_credit_contributions(group, durable_cash) do
    cancellation_ids =
      Repo.all(from record in OperationRecord, order_by: [asc: record.id])
      |> Enum.filter(fn record ->
        record.type in ["cancel_group", "cancel_rooms"] and
          record.result["group_id"] == group.group_id and
          record.result["status"] == "applied" and
          (record.result["credit_issued_cents"] || 0) > 0
      end)
      |> Enum.map(& &1.operation_id)

    case Repo.all(
           from lot in CreditLot,
             where: lot.source_operation_id in ^cancellation_ids,
             order_by: [asc: lot.id]
         ) do
      [] ->
        :ok

      [lot | _] ->
        unless Repo.exists?(
                 from contribution in CreditLotContribution,
                   where: contribution.credit_lot_id == ^lot.id
               ) do
          dispositions = backfilled_dispositions(group, durable_cash)

          ledger_converted =
            Repo.one(
              from entry in LedgerEntry,
                where: entry.group_id == ^group.id and entry.kind == "converted_to_credit",
                select: sum(entry.amount_cents)
            ) || 0

          durable_converted =
            Enum.sum(
              Enum.map(durable_cash, fn record ->
                Map.get(Map.get(dispositions, record.operation_id, %{}), :converted_to_credit, 0)
              end)
            )

          sources =
            [
              {nil, max(ledger_converted - durable_converted, 0)}
              | Enum.map(durable_cash, fn record ->
                  {record.operation_id,
                   Map.get(
                     Map.get(dispositions, record.operation_id, %{}),
                     :converted_to_credit,
                     0
                   )}
                end)
            ]
            |> Enum.filter(fn {_source, amount} -> amount > 0 end)

          add_credit_lot_contributions(lot, sources)
        end
    end
  end

  defp add_credit_lot_contributions(_lot, []), do: :ok

  defp add_credit_lot_contributions(lot, sources) do
    sources
    |> sort_funding_sources()
    |> Enum.reduce({0, 0}, fn {payment_operation_id, principal, _order},
                              {prior_cash, prior_value} ->
      current_cash = prior_cash + principal
      current_value = credit_value(current_cash)

      Repo.insert!(%CreditLotContribution{
        credit_lot_id: lot.id,
        payment_operation_id: payment_operation_id,
        principal_cents: principal,
        entitlement_cents: current_value - prior_value
      })

      {current_cash, current_value}
    end)

    :ok
  end

  defp cash_allocated?(group_id) do
    Repo.exists?(
      from allocation in CashAllocation,
        where: allocation.group_id == ^group_id
    )
  end

  defp allocation_key(%CashAllocation{id: id}), do: {:cash, id}
  defp allocation_key(%CreditAllocation{id: id}), do: {:credit, id}

  defp payment_allocated?(payment_operation_id) do
    Repo.exists?(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id
    )
  end

  defp prepare_existing_credit_fragments(allocations, categories) do
    fragments = build_credit_fragments(allocations, categories)
    Enum.each(allocations, &Repo.delete!/1)
    fragments
  end

  defp build_credit_fragments(allocations, categories) do
    {fragments, _remaining} =
      Enum.reduce(categories, {[], allocations}, fn {source, amount}, {fragments, remaining} ->
        {taken, next_remaining} = take_credit_fragments(remaining, source, amount, [])
        {fragments ++ taken, next_remaining}
      end)

    fragments
  end

  defp take_credit_fragments(allocations, _source, 0, fragments),
    do: {Enum.reverse(fragments), allocations}

  defp take_credit_fragments([], _source, _amount, fragments),
    do: {Enum.reverse(fragments), []}

  defp take_credit_fragments([allocation | allocations], source, amount, fragments) do
    taken = min(amount, allocation.amount_cents)

    fragment = %{
      source: source,
      credit_lot_id: allocation.credit_lot_id,
      amount: taken
    }

    remaining_allocation = allocation.amount_cents - taken

    next_allocations =
      if remaining_allocation > 0 do
        [%{allocation | amount_cents: remaining_allocation} | allocations]
      else
        allocations
      end

    take_credit_fragments(next_allocations, source, amount - taken, [fragment | fragments])
  end

  defp allocate_credit_fragments(group, fragments) do
    Enum.each(fragments, fn %{source: source, credit_lot_id: lot_id, amount: amount} ->
      {remaining, _} =
        Enum.reduce_while(active_rooms_for(group.id), {amount, :ok}, fn room, {remaining, :ok} ->
          allocated = min(remaining, room_capacity(room))

          if allocated > 0 do
            Repo.update!(
              Ecto.Changeset.change(room, credit_paid_cents: room.credit_paid_cents + allocated)
            )

            Repo.insert!(%CreditAllocation{
              group_id: group.id,
              room_id: room.id,
              credit_lot_id: lot_id,
              funding_operation_id: source,
              amount_cents: allocated,
              allocation_order: next_allocation_order()
            })
          end

          if allocated == remaining do
            {:halt, {0, :ok}}
          else
            {:cont, {remaining - allocated, :ok}}
          end
        end)

      if remaining != 0, do: raise(ArgumentError, "legacy credit exceeds room capacity")
    end)
  end

  defp ensure_payment_property_accounting(_group, payment_operation_id) do
    unless Repo.exists?(
             from accounting in PaymentPropertyAccounting,
               where: accounting.payment_operation_id == ^payment_operation_id
           ) do
      held_by_group =
        Repo.all(
          from allocation in CashAllocation,
            join: room in Room,
            on: room.id == allocation.room_id,
            join: group in Group,
            on: group.id == allocation.group_id,
            where:
              allocation.payment_operation_id == ^payment_operation_id and
                room.status == "active" and group.status == "active",
            group_by: allocation.group_id,
            select: {allocation.group_id, sum(allocation.amount_cents)}
        )

      Enum.each(held_by_group, fn {group_id, amount} ->
        Repo.insert!(%PaymentPropertyAccounting{
          payment_operation_id: payment_operation_id,
          group_id: group_id,
          held_cents: amount || 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 0,
          charged_back_cents: 0
        })
      end)

      payment = Repo.get_by!(PaymentAccounting, payment_operation_id: payment_operation_id)

      settled =
        payment.refunded_cents + payment.retained_cents + payment.converted_to_credit_cents

      if settled > 0 or held_by_group == [] do
        case Repo.get_by(PaymentPropertyAccounting,
               payment_operation_id: payment_operation_id,
               group_id: payment.group_id
             ) do
          nil ->
            Repo.insert!(%PaymentPropertyAccounting{
              payment_operation_id: payment_operation_id,
              group_id: payment.group_id,
              held_cents: 0,
              refunded_cents: payment.refunded_cents,
              retained_cents: payment.retained_cents,
              converted_to_credit_cents: payment.converted_to_credit_cents,
              reduced_cents: payment.reduced_cents,
              charged_back_cents: payment.charged_back_cents
            })

          accounting ->
            Repo.update!(
              Ecto.Changeset.change(accounting,
                refunded_cents: payment.refunded_cents,
                retained_cents: payment.retained_cents,
                converted_to_credit_cents: payment.converted_to_credit_cents,
                reduced_cents: payment.reduced_cents,
                charged_back_cents: payment.charged_back_cents
              )
            )
        end
      end
    end
  end

  defp adjust_payment_property_held(nil, _group_id, _amount), do: :ok

  defp adjust_payment_property_held(payment_operation_id, group_id, amount) do
    case Repo.get_by(PaymentPropertyAccounting,
           payment_operation_id: payment_operation_id,
           group_id: group_id
         ) do
      nil ->
        if amount > 0 do
          Repo.insert!(%PaymentPropertyAccounting{
            payment_operation_id: payment_operation_id,
            group_id: group_id,
            held_cents: amount,
            refunded_cents: 0,
            retained_cents: 0,
            converted_to_credit_cents: 0,
            reduced_cents: 0,
            charged_back_cents: 0
          })
        end

      accounting ->
        Repo.update!(
          Ecto.Changeset.change(accounting, held_cents: accounting.held_cents + amount)
        )
    end
  end

  defp adjust_payment_property_disposition(payment_operation_id, group_id, kind, amount) do
    field = String.to_atom("#{kind}_cents")

    case Repo.get_by(PaymentPropertyAccounting,
           payment_operation_id: payment_operation_id,
           group_id: group_id
         ) do
      nil ->
        :ok

      accounting ->
        Repo.update!(
          Ecto.Changeset.change(accounting, [
            {field, Map.get(accounting, field) + amount},
            held_cents: accounting.held_cents - amount
          ])
        )
    end
  end

  defp charge_back_property_dispositions(payment_operation_id) do
    Repo.all(
      from accounting in PaymentPropertyAccounting,
        where: accounting.payment_operation_id == ^payment_operation_id
    )
    |> Enum.each(fn accounting ->
      amount =
        accounting.held_cents + accounting.refunded_cents + accounting.retained_cents +
          accounting.converted_to_credit_cents

      Repo.update!(
        Ecto.Changeset.change(accounting,
          held_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: accounting.charged_back_cents + amount
        )
      )
    end)
  end

  defp rejection(operation, code, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id(operation),
        "status" => "rejected",
        "code" => code
      },
      extra
    )
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil

  defp operation_type(type) when is_binary(type), do: type
  defp operation_type(_type), do: nil
end
