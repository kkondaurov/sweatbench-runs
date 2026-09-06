defmodule GroupStay.FinanceReporting do
  @moduledoc """
  Stores the reporting inception position and the immutable finance movement journal.

  Report reads fold the snapshot and journal in memory. This avoids SQLite aggregate overflow and
  keeps passive hotel-credit expiry visible without changing domain state during a read.
  """

  import Ecto.Query

  alias GroupStay.{
    CreditAllocation,
    CreditLot,
    FinanceCashOpening,
    FinanceCreditOpening,
    FinanceMovement,
    FinanceReportingState,
    Group,
    Repo,
    Room
  }

  @active "active"

  @cash_kinds [
    "cash_received",
    "cash_transferred_in",
    "cash_transferred_out",
    "cash_refunded",
    "cash_retained",
    "cash_converted_to_credit",
    "cash_reduced",
    "cash_charged_back"
  ]

  @credit_kinds [
    "credit_issued",
    "credit_expired",
    "credit_consumed",
    "credit_revoked",
    "credit_absorbed"
  ]

  def started? do
    Repo.exists?(from(state in FinanceReportingState, where: state.id == 1))
  end

  def start(%Date{} = starts_on, operation_id) do
    if started?() do
      {:error, :already_started}
    else
      %FinanceReportingState{id: 1, starts_on: starts_on}
      |> Repo.insert!()

      snapshot_cash()
      snapshot_credit(starts_on, operation_id)
      :ok
    end
  end

  def close(%Date{} = period_end_on) do
    case Repo.get(FinanceReportingState, 1) do
      nil ->
        {:error, :invalid_period}

      %FinanceReportingState{} = state ->
        if valid_close?(state, period_end_on) do
          state
          |> Ecto.Changeset.change(latest_closed_on: period_end_on)
          |> Repo.update!()

          :ok
        else
          {:error, :invalid_period}
        end
    end
  end

  def record_cash(operation, property_id, kind, amount_cents)
      when kind in @cash_kinds and is_binary(property_id) and is_integer(amount_cents) do
    insert_at_posting_date(operation, property_id, nil, kind, amount_cents)
  end

  def record_credit(operation, kind, amount_cents)
      when kind in @credit_kinds and is_integer(amount_cents) do
    insert_at_posting_date(operation, nil, nil, kind, amount_cents)
  end

  def record_credit_issued(operation, %CreditLot{} = lot, amount_cents) do
    case posting_context(operation) do
      nil ->
        :ok

      {state, nominal_posting_on} ->
        insert_movement(
          operation,
          state,
          nominal_posting_on,
          nil,
          lot.id,
          "credit_issued",
          amount_cents
        )

        expiry_on = Date.add(lot.expires_on, 1)
        expiry_on = max_date(expiry_on, nominal_posting_on)

        if Date.compare(expiry_on, state.starts_on) in [:gt, :eq] do
          insert_movement(
            operation,
            state,
            expiry_on,
            nil,
            lot.id,
            "credit_expired",
            amount_cents
          )
        end
    end
  end

  def pause_credit_expiry(operation, %CreditLot{} = lot, amount_cents) do
    case posting_context(operation) do
      nil ->
        :ok

      {state, nominal_posting_on} ->
        natural_expiry = Date.add(lot.expires_on, 1)

        cond do
          Date.after?(natural_expiry, nominal_posting_on) and
              Date.compare(natural_expiry, state.starts_on) in [:gt, :eq] ->
            insert_movement(
              operation,
              state,
              natural_expiry,
              nil,
              lot.id,
              "credit_expired",
              -amount_cents
            )

          Date.compare(natural_expiry, state.starts_on) in [:lt, :eq] ->
            insert_movement(
              operation,
              state,
              nominal_posting_on,
              nil,
              lot.id,
              "credit_expired",
              -amount_cents
            )

          true ->
            :ok
        end
    end
  end

  def restore_credit(operation, %CreditLot{} = lot, available_cents, absorbed_cents) do
    case posting_context(operation) do
      nil ->
        :ok

      {state, nominal_posting_on} ->
        if absorbed_cents > 0 do
          insert_movement(
            operation,
            state,
            nominal_posting_on,
            nil,
            lot.id,
            "credit_absorbed",
            absorbed_cents
          )
        end

        if available_cents > 0 do
          natural_expiry = Date.add(lot.expires_on, 1)
          expiry_on = max_date(natural_expiry, nominal_posting_on)

          if Date.compare(expiry_on, state.starts_on) in [:gt, :eq] do
            insert_movement(
              operation,
              state,
              expiry_on,
              nil,
              lot.id,
              "credit_expired",
              available_cents
            )
          end
        end
    end
  end

  def record_credit_revoked(operation, %CreditLot{} = lot, amount_cents) do
    case posting_context(operation) do
      nil ->
        :ok

      {state, nominal_posting_on} ->
        natural_expiry = Date.add(lot.expires_on, 1)

        if Date.after?(natural_expiry, nominal_posting_on) and
             Date.compare(natural_expiry, state.starts_on) in [:gt, :eq] do
          insert_movement(
            operation,
            state,
            nominal_posting_on,
            nil,
            lot.id,
            "credit_revoked",
            amount_cents
          )

          insert_movement(
            operation,
            state,
            natural_expiry,
            nil,
            lot.id,
            "credit_expired",
            -amount_cents
          )
        end
    end
  end

  def daily_report(%Date{} = date) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get(FinanceReportingState, 1) do
          nil ->
            {:error, :not_available}

          %FinanceReportingState{starts_on: starts_on} = state ->
            if Date.before?(date, starts_on) do
              {:error, :not_available}
            else
              status =
                if state.latest_closed_on &&
                     Date.compare(date, state.latest_closed_on) in [:lt, :eq],
                   do: "closed",
                   else: "open"

              {:ok, build_report(date, status)}
            end
        end
      end)

    result
  end

  defp snapshot_cash do
    from(group in Group,
      where: group.cash_held_cents != 0,
      select: {group.group_id, group.property_id, group.cash_held_cents}
    )
    |> Repo.all()
    |> Enum.each(fn {group_id, property_id, amount_cents} ->
      %FinanceCashOpening{
        group_id: group_id,
        property_id: property_id,
        amount_cents: amount_cents
      }
      |> Repo.insert!()
    end)
  end

  defp snapshot_credit(starts_on, operation_id) do
    applied_by_lot =
      from(allocation in CreditAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: room.status == @active,
        select: {allocation.credit_lot_id, allocation.amount_cents}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {lot_id, amount}, totals ->
        Map.update(totals, lot_id, amount, &(&1 + amount))
      end)

    from(lot in CreditLot, order_by: [asc: lot.id])
    |> Repo.all()
    |> Enum.each(fn lot ->
      available =
        if Date.compare(lot.expires_on, starts_on) in [:gt, :eq], do: lot.remaining_cents, else: 0

      applied = Map.get(applied_by_lot, lot.id, 0)

      if available > 0 or applied > 0 do
        %FinanceCreditOpening{
          credit_lot_id: lot.id,
          available_cents: available,
          applied_cents: applied,
          expires_on: lot.expires_on
        }
        |> Repo.insert!()
      end

      if available > 0 do
        %FinanceMovement{
          operation_id: operation_id,
          posting_on: Date.add(lot.expires_on, 1),
          credit_lot_id: lot.id,
          kind: "credit_expired",
          amount_cents: available
        }
        |> Repo.insert!()
      end
    end)
  end

  defp insert_at_posting_date(operation, property_id, credit_lot_id, kind, amount_cents) do
    case posting_context(operation) do
      nil ->
        :ok

      {state, nominal_posting_on} ->
        insert_movement(
          operation,
          state,
          nominal_posting_on,
          property_id,
          credit_lot_id,
          kind,
          amount_cents
        )
    end
  end

  defp insert_movement(_operation, _state, _nominal_on, _property_id, _lot_id, _kind, 0),
    do: :ok

  defp insert_movement(
         operation,
         state,
         nominal_posting_on,
         property_id,
         lot_id,
         kind,
         amount_cents
       ) do
    posting_on = published_posting_on(state, nominal_posting_on)

    %FinanceMovement{
      operation_id: operation["operation_id"],
      posting_on: posting_on,
      property_id: property_id,
      credit_lot_id: lot_id,
      kind: kind,
      amount_cents: amount_cents,
      late_adjustment: Date.after?(posting_on, nominal_posting_on)
    }
    |> Repo.insert!()

    :ok
  end

  defp posting_context(operation) do
    with %FinanceReportingState{} = state <- Repo.get(FinanceReportingState, 1),
         {:ok, occurred_on} <- Date.from_iso8601(operation["occurred_on"]) do
      nominal_posting_on =
        if Date.before?(occurred_on, state.starts_on), do: state.starts_on, else: occurred_on

      {state, nominal_posting_on}
    else
      _ -> nil
    end
  end

  defp build_report(date, status) do
    {cash, late_cash} = cash_reports(date)
    {credit, late_credit} = credit_reports(date)

    %{
      date: Date.to_iso8601(date),
      status: status,
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp cash_reports(date) do
    opening =
      from(opening in FinanceCashOpening,
        select: {opening.property_id, opening.amount_cents}
      )
      |> Repo.all()
      |> sum_by_key()

    movements =
      from(movement in FinanceMovement,
        where: movement.kind in ^@cash_kinds and movement.posting_on <= ^date,
        select: {
          movement.property_id,
          movement.posting_on,
          movement.kind,
          movement.amount_cents,
          movement.late_adjustment
        }
      )
      |> Repo.all()

    properties =
      (Map.keys(opening) ++ Enum.map(movements, &elem(&1, 0)))
      |> Enum.uniq()
      |> Enum.sort()

    entries =
      properties
      |> Enum.map(&cash_entry(&1, Map.get(opening, &1, 0), movements, date))
      |> Enum.reject(&is_nil/1)

    late_entries =
      properties
      |> Enum.map(&late_cash_entry(&1, movements, date))
      |> Enum.reject(&is_nil/1)

    {entries, late_entries}
  end

  defp cash_entry(property_id, inception, movements, date) do
    prior =
      Enum.filter(movements, fn {property, posting_on, _kind, _amount, _late} ->
        property == property_id and Date.before?(posting_on, date)
      end)

    today =
      Enum.filter(movements, fn {property, posting_on, _kind, _amount, _late} ->
        property == property_id and posting_on == date
      end)

    ordinary_today = Enum.reject(today, &elem(&1, 4))

    opening_held = inception + cash_net(prior)
    movement_map = cash_movement_map(ordinary_today)
    closing_held = opening_held + cash_net(today)

    entry = %{
      property_id: property_id,
      opening_held_cents: opening_held,
      movements: movement_map,
      closing_held_cents: closing_held
    }

    late_movement_map =
      today
      |> Enum.filter(&elem(&1, 4))
      |> cash_movement_map()

    if opening_held == 0 and closing_held == 0 and all_zero?(movement_map) and
         all_zero?(late_movement_map),
       do: nil,
       else: entry
  end

  defp late_cash_entry(property_id, movements, date) do
    late_today =
      Enum.filter(movements, fn {property, posting_on, _kind, _amount, late} ->
        property == property_id and posting_on == date and late
      end)

    movement_map = cash_movement_map(late_today)

    if all_zero?(movement_map),
      do: nil,
      else: %{property_id: property_id, movements: movement_map}
  end

  defp cash_movement_map(rows) do
    totals =
      Enum.reduce(rows, %{}, fn {_property, _posting, kind, amount, _late}, acc ->
        Map.update(acc, kind, amount, &(&1 + amount))
      end)

    %{
      received_cents: Map.get(totals, "cash_received", 0),
      transferred_in_cents: Map.get(totals, "cash_transferred_in", 0),
      transferred_out_cents: Map.get(totals, "cash_transferred_out", 0),
      refunded_cents: Map.get(totals, "cash_refunded", 0),
      retained_cents: Map.get(totals, "cash_retained", 0),
      converted_to_credit_cents: Map.get(totals, "cash_converted_to_credit", 0),
      reduced_cents: Map.get(totals, "cash_reduced", 0),
      charged_back_cents: Map.get(totals, "cash_charged_back", 0)
    }
  end

  defp cash_net(rows) do
    Enum.reduce(rows, 0, fn {_property, _posting, kind, amount, _late}, total ->
      coefficient = if kind in ["cash_received", "cash_transferred_in"], do: 1, else: -1
      total + coefficient * amount
    end)
  end

  defp credit_reports(date) do
    opening_liability =
      from(opening in FinanceCreditOpening,
        select: {opening.available_cents, opening.applied_cents}
      )
      |> Repo.all()
      |> Enum.reduce(0, fn {available, applied}, total -> total + available + applied end)

    movements =
      from(movement in FinanceMovement,
        where: movement.kind in ^@credit_kinds and movement.posting_on <= ^date,
        select: {
          movement.posting_on,
          movement.kind,
          movement.amount_cents,
          movement.late_adjustment
        }
      )
      |> Repo.all()

    prior =
      Enum.filter(movements, fn {posting_on, _kind, _amount, _late} ->
        Date.before?(posting_on, date)
      end)

    today =
      Enum.filter(movements, fn {posting_on, _kind, _amount, _late} -> posting_on == date end)

    ordinary_today = Enum.reject(today, &elem(&1, 3))
    late_today = Enum.filter(today, &elem(&1, 3))

    opening = opening_liability + credit_net(prior)
    movement_map = credit_movement_map(ordinary_today)

    {
      %{
        opening_liability_cents: opening,
        movements: movement_map,
        closing_liability_cents: opening + credit_net(today)
      },
      credit_movement_map(late_today)
    }
  end

  defp credit_movement_map(rows) do
    totals =
      Enum.reduce(rows, %{}, fn {_posting, kind, amount, _late}, acc ->
        Map.update(acc, kind, amount, &(&1 + amount))
      end)

    %{
      issued_cents: Map.get(totals, "credit_issued", 0),
      expired_cents: Map.get(totals, "credit_expired", 0),
      consumed_cents: Map.get(totals, "credit_consumed", 0),
      revoked_cents: Map.get(totals, "credit_revoked", 0),
      absorbed_cents: Map.get(totals, "credit_absorbed", 0)
    }
  end

  defp credit_net(rows) do
    Enum.reduce(rows, 0, fn {_posting, kind, amount, _late}, total ->
      coefficient = if kind == "credit_issued", do: 1, else: -1
      total + coefficient * amount
    end)
  end

  defp sum_by_key(rows) do
    Enum.reduce(rows, %{}, fn {key, amount}, totals ->
      Map.update(totals, key, amount, &(&1 + amount))
    end)
  end

  defp valid_close?(state, period_end_on) do
    Date.compare(period_end_on, state.starts_on) in [:gt, :eq] and
      (is_nil(state.latest_closed_on) or Date.after?(period_end_on, state.latest_closed_on))
  end

  defp published_posting_on(%FinanceReportingState{latest_closed_on: nil}, nominal_posting_on),
    do: nominal_posting_on

  defp published_posting_on(
         %FinanceReportingState{latest_closed_on: latest_closed_on},
         nominal_posting_on
       ) do
    max_date(nominal_posting_on, Date.add(latest_closed_on, 1))
  end

  defp max_date(left, right) do
    if Date.after?(left, right), do: left, else: right
  end

  defp all_zero?(movements),
    do: Enum.all?(movements, fn {_classification, amount} -> amount == 0 end)
end
