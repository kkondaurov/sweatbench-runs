defmodule GroupStay.Finance do
  import Ecto.Query

  alias GroupStay.FinanceMovement
  alias GroupStay.FinanceReporting
  alias GroupStay.Groups.{CashAllocation, CreditAllocation, CreditLot, Group}
  alias GroupStay.Repo

  @cash_movement_keys ~w(
    received_cents
    transferred_in_cents
    transferred_out_cents
    refunded_cents
    retained_cents
    converted_to_credit_cents
    reduced_cents
    charged_back_cents
  )

  @credit_movement_keys ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  @doc "Returns the reporting configuration, if finance reporting has started."
  def reporting, do: Repo.one(FinanceReporting)

  @doc "Captures domain state used to calculate a reporting movement."
  def snapshot do
    groups =
      Repo.all(Group)
      |> Map.new(fn group ->
        {group.group_id,
         %{
           property_id: group.property_id,
           status: group.status,
           rate_plan: group.rate_plan,
           booked_on: group.booked_on,
           arrival_on: group.arrival_on
         }}
      end)

    cash =
      Repo.all(CashAllocation)
      |> Enum.map(fn allocation ->
        %{
          id: allocation.id,
          group_id: allocation.group_id,
          held_cents: allocation.held_cents,
          refunded_cents: allocation.refunded_cents,
          retained_cents: allocation.retained_cents,
          converted_to_credit_cents: allocation.converted_to_credit_cents,
          reduced_cents: allocation.reduced_cents,
          charged_back_cents: allocation.charged_back_cents
        }
      end)

    lots =
      Repo.all(CreditLot)
      |> Map.new(fn lot ->
        {lot.id,
         %{
           remaining_cents: lot.remaining_cents,
           unrecovered_clawback_cents: lot.unrecovered_clawback_cents || 0,
           expires_on: lot.expires_on
         }}
      end)

    credit_allocations =
      Repo.all(CreditAllocation)
      |> Enum.map(fn allocation ->
        %{lot_id: allocation.credit_lot_id, amount_cents: allocation.amount_cents}
      end)

    %{groups: groups, cash: cash, lots: lots, credit_allocations: credit_allocations}
  end

  @doc "Stores the reporting inception position."
  def start_reporting!(starts_on, snapshot) do
    opening_cash = held_cash_by_property(snapshot)

    opening_credit_lots =
      snapshot.lots
      |> Enum.map(fn {lot_id, lot} ->
        available =
          if Date.compare(lot.expires_on, starts_on) in [:eq, :gt],
            do: lot.remaining_cents,
            else: 0

        {Integer.to_string(lot_id),
         %{
           "available_cents" => available,
           "expires_on" => Date.to_iso8601(lot.expires_on)
         }}
      end)
      |> Map.new()

    Repo.insert!(%FinanceReporting{
      id: 1,
      starts_on: starts_on,
      opening_cash: opening_cash,
      opening_credit_cents: credit_liability(starts_on),
      opening_credit_lots: opening_credit_lots
    })
  end

  @doc "Records the financial effect of an applied operation after reporting starts."
  def record_operation(operation, before, after_snapshot) do
    case reporting() do
      nil ->
        :ok

      reporting ->
        cash_movements = cash_movements(operation, before, after_snapshot)
        credit_events = credit_events(operation, before, after_snapshot)

        if cash_movements != %{} or credit_events != %{} do
          Repo.insert!(%FinanceMovement{
            operation_id: operation["operation_id"],
            posting_on: posting_date(operation, reporting.starts_on),
            cash_movements: cash_movements,
            credit_events: credit_events
          })
        end

        :ok
    end
  end

  @doc "Returns the report for one date, or a reporting availability error."
  def daily_report(date) do
    case reporting() do
      nil ->
        {:error, :report_not_available}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, :report_not_available}
        else
          movements = finance_movements()

          {:ok,
           %{
             date: Date.to_iso8601(date),
             status: "open",
             cash: cash_report(reporting, movements, date),
             credit: credit_report(reporting, movements, date)
           }}
        end
    end
  end

  defp cash_report(reporting, movements, date) do
    before =
      cash_totals(movements, fn movement -> Date.compare(movement.posting_on, date) == :lt end)

    today =
      cash_totals(movements, fn movement -> Date.compare(movement.posting_on, date) == :eq end)

    opening_cash = normalize_integer_map(reporting.opening_cash)

    properties =
      opening_cash
      |> Map.keys()
      |> Kernel.++(Map.keys(before))
      |> Kernel.++(Map.keys(today))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(properties, fn property_id ->
      opening =
        Map.get(opening_cash, property_id, 0) + cash_net(Map.get(before, property_id, %{}))

      movement = Map.get(today, property_id, %{})
      closing = opening + cash_net(movement)

      if opening == 0 and closing == 0 and cash_values_zero?(movement) do
        []
      else
        [
          %{
            property_id: property_id,
            opening_held_cents: opening,
            movements: complete_cash_movements(movement),
            closing_held_cents: closing
          }
        ]
      end
    end)
  end

  defp credit_report(reporting, movements, date) do
    {_states, credit_by_date} = credit_timeline(reporting, movements, date)

    before =
      credit_totals(credit_by_date, fn movement_date ->
        Date.compare(movement_date, date) == :lt
      end)

    today = Map.get(credit_by_date, date, zero_credit_movements())
    opening = reporting.opening_credit_cents + credit_net(before)
    closing = opening + credit_net(today)

    %{
      opening_liability_cents: opening,
      movements: complete_credit_movements(today),
      closing_liability_cents: closing
    }
  end

  defp finance_movements do
    from(m in FinanceMovement, order_by: [asc: m.id])
    |> Repo.all()
  end

  defp cash_totals(movements, include?) do
    movements
    |> Enum.filter(include?)
    |> Enum.reduce(%{}, fn movement, totals ->
      Enum.reduce(movement.cash_movements || %{}, totals, fn {property_id, values}, totals ->
        Map.update(totals, property_id, normalize_cash_values(values), fn current ->
          add_cash_values(current, normalize_cash_values(values))
        end)
      end)
    end)
  end

  defp cash_net(movement) do
    movement = normalize_cash_values(movement)

    movement.received_cents + movement.transferred_in_cents - movement.transferred_out_cents -
      movement.refunded_cents - movement.retained_cents - movement.converted_to_credit_cents -
      movement.reduced_cents - movement.charged_back_cents
  end

  defp cash_values_zero?(movement) do
    movement
    |> normalize_cash_values()
    |> Map.values()
    |> Enum.all?(&(&1 == 0))
  end

  defp complete_cash_movements(movement) do
    values = normalize_cash_values(movement)

    %{
      received_cents: values.received_cents,
      transferred_in_cents: values.transferred_in_cents,
      transferred_out_cents: values.transferred_out_cents,
      refunded_cents: values.refunded_cents,
      retained_cents: values.retained_cents,
      converted_to_credit_cents: values.converted_to_credit_cents,
      reduced_cents: values.reduced_cents,
      charged_back_cents: values.charged_back_cents
    }
  end

  defp normalize_cash_values(values) do
    Enum.reduce(@cash_movement_keys, %{}, fn key, normalized ->
      Map.put(
        normalized,
        String.to_atom(key),
        Map.get(values, key, Map.get(values, String.to_atom(key), 0))
      )
    end)
  end

  defp add_cash_values(left, right) do
    Enum.reduce(@cash_movement_keys, %{}, fn key, values ->
      atom_key = String.to_atom(key)
      Map.put(values, atom_key, Map.get(left, atom_key, 0) + Map.get(right, atom_key, 0))
    end)
  end

  defp normalize_integer_map(map) do
    Map.new(map || %{}, fn {key, value} -> {key, value} end)
  end

  defp held_cash_by_property(snapshot) do
    snapshot.cash
    |> Enum.filter(fn allocation -> allocation.held_cents > 0 end)
    |> Enum.reduce(%{}, fn allocation, totals ->
      if get_in(snapshot.groups, [allocation.group_id, :status]) == "active" do
        property_id = get_in(snapshot.groups, [allocation.group_id, :property_id])
        Map.update(totals, property_id, allocation.held_cents, &(&1 + allocation.held_cents))
      else
        totals
      end
    end)
  end

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from a in CreditAllocation,
          join: g in Group,
          on: g.group_id == a.group_id,
          where: g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + applied
  end

  defp credit_events(operation, before, after_snapshot) do
    type = operation["type"]

    events =
      case type do
        "apply_hotel_credit" ->
          apply_credit_events(before, after_snapshot)

        type when type in ["cancel_group", "cancel_rooms"] ->
          cancellation_credit_events(operation, before, after_snapshot)

        "charge_back_payment" ->
          revoke_credit_events(before, after_snapshot)

        _ ->
          %{}
      end

    events
    |> add_issued_credit_events(before, after_snapshot)
  end

  defp add_issued_credit_events(events, before, after_snapshot) do
    Enum.reduce(after_snapshot.lots, events, fn {lot_id, lot}, events ->
      unless Map.has_key?(before.lots, lot_id) do
        append_credit_event(events, lot_id, %{
          "type" => "issue",
          "amount_cents" => lot.remaining_cents,
          "expires_on" => Date.to_iso8601(lot.expires_on)
        })
      else
        events
      end
    end)
  end

  defp apply_credit_events(before, after_snapshot) do
    before_allocations = credit_allocation_totals(before)
    after_allocations = credit_allocation_totals(after_snapshot)

    Enum.reduce(after_allocations, %{}, fn {lot_id, amount}, events ->
      added = amount - Map.get(before_allocations, lot_id, 0)

      if added > 0 do
        append_credit_event(events, lot_id, %{"type" => "apply", "amount_cents" => added})
      else
        events
      end
    end)
  end

  defp cancellation_credit_events(operation, before, after_snapshot) do
    before_allocations = credit_allocation_totals(before)
    after_allocations = credit_allocation_totals(after_snapshot)
    refundable = refundable_cancellation?(operation, before)

    Enum.reduce(before_allocations, %{}, fn {lot_id, amount}, events ->
      removed = amount - Map.get(after_allocations, lot_id, 0)

      if removed > 0 do
        before_lot = Map.fetch!(before.lots, lot_id)
        after_lot = Map.fetch!(after_snapshot.lots, lot_id)

        restored = refundable

        if restored do
          absorbed =
            max(
              before_lot.unrecovered_clawback_cents - after_lot.unrecovered_clawback_cents,
              0
            )

          available = max(after_lot.remaining_cents - before_lot.remaining_cents, 0)
          expired = max(removed - absorbed - available, 0)

          append_credit_event(events, lot_id, %{
            "type" => "restore",
            "amount_cents" => removed,
            "available_cents" => available,
            "absorbed_cents" => absorbed,
            "expired_cents" => expired
          })
        else
          append_credit_event(events, lot_id, %{"type" => "consume", "amount_cents" => removed})
        end
      else
        events
      end
    end)
  end

  defp refundable_cancellation?(operation, snapshot) do
    group = snapshot.groups[operation["group_id"]]

    with %{rate_plan: rate_plan, booked_on: booked_on, arrival_on: arrival_on} <- group,
         {:ok, occurred_on} <- Date.from_iso8601(operation["occurred_on"]) do
      refundable_until =
        case rate_plan do
          "advance_purchase" ->
            nil

          "flexible" ->
            days = if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: 14, else: 30
            Date.add(arrival_on, -days)

          _ ->
            nil
        end

      refundable_until != nil and Date.compare(occurred_on, refundable_until) != :gt
    else
      _ -> false
    end
  end

  defp revoke_credit_events(before, after_snapshot) do
    Enum.reduce(before.lots, %{}, fn {lot_id, lot}, events ->
      after_lot = Map.get(after_snapshot.lots, lot_id, lot)
      revoked = lot.remaining_cents - after_lot.remaining_cents

      if revoked > 0 do
        append_credit_event(events, lot_id, %{"type" => "revoke", "amount_cents" => revoked})
      else
        events
      end
    end)
  end

  defp credit_allocation_totals(snapshot) do
    Enum.reduce(snapshot.credit_allocations, %{}, fn allocation, totals ->
      Map.update(
        totals,
        allocation.lot_id,
        allocation.amount_cents,
        &(&1 + allocation.amount_cents)
      )
    end)
  end

  defp append_credit_event(events, lot_id, event) do
    key = Integer.to_string(lot_id)
    Map.update(events, key, [event], &(&1 ++ [event]))
  end

  defp credit_timeline(reporting, movements, date) do
    states = initial_credit_states(reporting)
    by_date = %{}

    {states, by_date} =
      movements
      |> Enum.filter(&(Date.compare(&1.posting_on, date) in [:lt, :eq]))
      |> Enum.reduce({states, by_date}, fn movement, {states, by_date} ->
        Enum.reduce(movement.credit_events || %{}, {states, by_date}, fn {lot_id, events}, acc ->
          Enum.reduce(events, acc, fn event, {states, by_date} ->
            apply_credit_event(
              states,
              by_date,
              lot_id,
              event,
              movement.posting_on
            )
          end)
        end)
      end)

    expire_credit_lots(states, date, reporting.starts_on, by_date)
  end

  defp initial_credit_states(reporting) do
    Map.new(reporting.opening_credit_lots || %{}, fn {lot_id, lot} ->
      expires_on = Date.from_iso8601!(lot["expires_on"] || lot[:expires_on])
      expiry_date = Date.add(expires_on, 1)

      {lot_id,
       %{
         available_cents: lot["available_cents"] || lot[:available_cents] || 0,
         expires_on: expires_on,
         expired: Date.compare(expiry_date, reporting.starts_on) != :gt,
         expiry_visible: Date.compare(expiry_date, reporting.starts_on) == :gt,
         deferred_expiry: false
       }}
    end)
  end

  defp expire_credit_lots(states, through, starts_on, by_date) do
    Enum.reduce(states, {states, by_date}, fn {lot_id, state}, {states, by_date} ->
      if state.expires_on do
        expiry_date = Date.add(state.expires_on, 1)

        if not state.expired and Date.compare(expiry_date, through) in [:lt, :eq] do
          states = Map.put(states, lot_id, %{state | available_cents: 0, expired: true})

          by_date =
            if state.expiry_visible and Date.compare(expiry_date, starts_on) != :lt do
              add_credit_movement(by_date, expiry_date, "expired_cents", state.available_cents)
            else
              by_date
            end

          {states, by_date}
        else
          {states, by_date}
        end
      else
        {states, by_date}
      end
    end)
  end

  defp apply_credit_event(states, by_date, lot_id, event, event_date) do
    type = event["type"] || event[:type]
    amount = event["amount_cents"] || event[:amount_cents] || 0

    state =
      Map.get(states, lot_id) ||
        %{
          available_cents: 0,
          expires_on: nil,
          expired: false,
          expiry_visible: true,
          deferred_expiry: false
        }

    case type do
      "issue" ->
        expires_on = event_expiry(event)
        expired_at_issue = Date.compare(Date.add(expires_on, 1), event_date) != :gt
        effective_expires_on = if expired_at_issue, do: Date.add(event_date, -1), else: expires_on

        state = %{
          state
          | available_cents: state.available_cents + amount,
            expires_on: effective_expires_on,
            expired: false,
            expiry_visible: true,
            deferred_expiry: expired_at_issue
        }

        states = Map.put(states, lot_id, state)
        by_date = add_credit_movement(by_date, event_date, "issued_cents", amount)
        {states, by_date}

      "apply" ->
        available = max(state.available_cents - amount, 0)
        {Map.put(states, lot_id, %{state | available_cents: available}), by_date}

      "consume" ->
        {states, add_credit_movement(by_date, event_date, "consumed_cents", amount)}

      "revoke" ->
        expired =
          state.expired or
            ((not state.deferred_expiry and state.expires_on) &&
               Date.compare(Date.add(state.expires_on, 1), event_date) != :gt)

        revoked = if expired, do: 0, else: min(state.available_cents, amount)
        state = %{state | available_cents: state.available_cents - revoked}

        {
          Map.put(states, lot_id, state),
          add_credit_movement(by_date, event_date, "revoked_cents", revoked)
        }

      "restore" ->
        available = event["available_cents"] || event[:available_cents] || 0
        absorbed = event["absorbed_cents"] || event[:absorbed_cents] || 0
        expired = event["expired_cents"] || event[:expired_cents] || 0
        state = %{state | available_cents: state.available_cents + available}

        by_date = add_credit_movement(by_date, event_date, "absorbed_cents", absorbed)
        by_date = add_credit_movement(by_date, event_date, "expired_cents", expired)
        {Map.put(states, lot_id, state), by_date}

      _ ->
        {states, by_date}
    end
  end

  defp event_expiry(event) do
    Date.from_iso8601!(event["expires_on"] || event[:expires_on])
  end

  defp add_credit_movement(by_date, date, key, amount) when amount > 0 do
    Map.update(by_date, date, Map.put(zero_credit_movements(), key, amount), fn current ->
      Map.update(current, key, amount, &(&1 + amount))
    end)
  end

  defp add_credit_movement(by_date, _date, _key, _amount), do: by_date

  defp credit_totals(by_date, include?) do
    by_date
    |> Enum.filter(fn {date, _movement} -> include?.(date) end)
    |> Enum.reduce(zero_credit_movements(), fn {_date, movement}, totals ->
      Enum.reduce(@credit_movement_keys, totals, fn key, totals ->
        Map.update(totals, key, Map.get(movement, key, 0), &(&1 + Map.get(movement, key, 0)))
      end)
    end)
  end

  defp credit_net(movement) do
    movement = Enum.reduce(@credit_movement_keys, %{}, &Map.put(&2, &1, Map.get(movement, &1, 0)))

    movement["issued_cents"] - movement["expired_cents"] - movement["consumed_cents"] -
      movement["revoked_cents"] - movement["absorbed_cents"]
  end

  defp complete_credit_movements(movement) do
    %{
      issued_cents: Map.get(movement, "issued_cents", 0),
      expired_cents: Map.get(movement, "expired_cents", 0),
      consumed_cents: Map.get(movement, "consumed_cents", 0),
      revoked_cents: Map.get(movement, "revoked_cents", 0),
      absorbed_cents: Map.get(movement, "absorbed_cents", 0)
    }
  end

  defp zero_credit_movements, do: Map.new(@credit_movement_keys, &{&1, 0})

  defp posting_date(operation, starts_on) do
    case Date.from_iso8601(operation["occurred_on"] || "") do
      {:ok, occurred_on} ->
        if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on

      {:error, _reason} ->
        starts_on
    end
  end

  defp cash_movements(operation, before, after_snapshot) do
    case operation["type"] do
      "record_cash_payment" ->
        property_id = get_in(after_snapshot.groups, [operation["group_id"], :property_id])
        %{property_id => %{"received_cents" => operation["amount_cents"]}}

      "transfer_deposit" ->
        source_property =
          get_in(after_snapshot.groups, [operation["source_group_id"], :property_id])

        destination_property =
          get_in(after_snapshot.groups, [operation["destination_group_id"], :property_id])

        amount =
          max(
            held_cash_for_group(before, operation["source_group_id"]) -
              held_cash_for_group(after_snapshot, operation["source_group_id"]),
            0
          )

        %{}
        |> put_cash_movement(source_property, "transferred_out_cents", amount)
        |> put_cash_movement(destination_property, "transferred_in_cents", amount)

      type when type in ["cancel_group", "cancel_rooms"] ->
        cash_field_differences(before, after_snapshot, [
          {:refunded_cents, "refunded_cents"},
          {:retained_cents, "retained_cents"},
          {:converted_to_credit_cents, "converted_to_credit_cents"}
        ])

      "reduce_cash_payment" ->
        cash_field_differences(before, after_snapshot, [{:reduced_cents, "reduced_cents"}])

      "charge_back_payment" ->
        cash_field_differences(before, after_snapshot, [
          {:refunded_cents, "refunded_cents"},
          {:retained_cents, "retained_cents"},
          {:converted_to_credit_cents, "converted_to_credit_cents"},
          {:charged_back_cents, "charged_back_cents"}
        ])

      _ ->
        %{}
    end
  end

  defp held_cash_for_group(snapshot, group_id) do
    snapshot.cash
    |> Enum.filter(&(&1.group_id == group_id))
    |> Enum.map(& &1.held_cents)
    |> Enum.sum()
  end

  defp cash_field_differences(before, after_snapshot, fields) do
    before_totals = cash_property_totals(before)
    after_totals = cash_property_totals(after_snapshot)
    properties = (Map.keys(before_totals) ++ Map.keys(after_totals)) |> Enum.uniq()

    Enum.reduce(properties, %{}, fn property_id, movements ->
      Enum.reduce(fields, movements, fn {field, movement_key}, movements ->
        before_value = get_in(before_totals, [property_id, field]) || 0
        after_value = get_in(after_totals, [property_id, field]) || 0
        put_cash_movement(movements, property_id, movement_key, after_value - before_value)
      end)
    end)
  end

  defp cash_property_totals(snapshot) do
    Enum.reduce(snapshot.cash, %{}, fn allocation, totals ->
      property_id = get_in(snapshot.groups, [allocation.group_id, :property_id])

      if property_id do
        values = Map.drop(allocation, [:id, :group_id])

        Map.update(totals, property_id, values, fn current ->
          Enum.reduce(values, current, fn {key, value}, current ->
            Map.update(current, key, value, &(&1 + value))
          end)
        end)
      else
        totals
      end
    end)
  end

  defp put_cash_movement(movements, _property_id, _key, 0), do: movements

  defp put_cash_movement(movements, property_id, key, amount) do
    Map.update(movements, property_id, %{key => amount}, fn current ->
      Map.update(current, key, amount, &(&1 + amount))
    end)
  end
end
