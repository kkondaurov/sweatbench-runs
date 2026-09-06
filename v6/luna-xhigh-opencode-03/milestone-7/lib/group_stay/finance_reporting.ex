defmodule GroupStay.FinanceReporting do
  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CreditLot,
    CreditLotBalanceEvent,
    FinanceEvent,
    FinanceReportSnapshot,
    FinanceReportingState,
    Group,
    GroupCreditAllocation,
    Repo
  }

  @cash_fields [
    :received_cents,
    :transferred_in_cents,
    :transferred_out_cents,
    :refunded_cents,
    :retained_cents,
    :converted_to_credit_cents,
    :reduced_cents,
    :charged_back_cents
  ]

  @credit_fields [:issued_cents, :expired_cents, :consumed_cents, :revoked_cents, :absorbed_cents]

  def started? do
    Repo.exists?(from state in FinanceReportingState, select: state.id)
  end

  def starts_on do
    case Repo.one(from state in FinanceReportingState, select: state.starts_on) do
      nil -> nil
      starts_on -> starts_on
    end
  end

  def latest_close_on do
    Repo.one(from state in FinanceReportingState, select: state.latest_close_on)
  end

  def start!(starts_on) do
    opening_cash =
      Repo.all(
        from allocation in CashAllocation,
          join: group in Group,
          on: group.id == allocation.group_record_id,
          where: allocation.disposition == "held" and group.status == "active",
          group_by: group.property_id,
          select: {group.property_id, coalesce(sum(allocation.amount_cents), 0)}
      )
      |> Map.new()

    opening_credit_liability = credit_liability(starts_on)

    %FinanceReportingState{}
    |> FinanceReportingState.changeset(%{
      starts_on: starts_on,
      opening_cash_json: Jason.encode!(opening_cash),
      opening_credit_liability_cents: opening_credit_liability
    })
    |> Repo.insert!()
  end

  def posting_date(operation) when is_map(operation) do
    case Repo.one(from state in FinanceReportingState, select: state.starts_on) do
      nil -> nil
      starts_on -> max_date(parse_date(Map.get(operation, "occurred_on")), starts_on)
    end
  end

  def reporting_posting_date(operation) when is_map(operation) do
    case Repo.one(
           from state in FinanceReportingState, select: {state.starts_on, state.latest_close_on}
         ) do
      nil ->
        nil

      {starts_on, latest_close_on} ->
        base_posting_on = max_date(parse_date(Map.get(operation, "occurred_on")), starts_on)

        case latest_close_on do
          nil ->
            {base_posting_on, false}

          latest_close_on ->
            first_open_date = Date.add(latest_close_on, 1)

            if Date.compare(base_posting_on, first_open_date) == :lt do
              {first_open_date, true}
            else
              {base_posting_on, false}
            end
        end
    end
  end

  def close(period_end_on) do
    case Repo.one(from(state in FinanceReportingState)) do
      nil ->
        {:error, :invalid_period}

      state ->
        valid_period? =
          Date.compare(period_end_on, state.starts_on) != :lt and
            (is_nil(state.latest_close_on) or
               Date.compare(period_end_on, state.latest_close_on) == :gt)

        if valid_period? do
          first_date =
            case state.latest_close_on do
              nil -> state.starts_on
              latest_close_on -> Date.add(latest_close_on, 1)
            end

          first_date
          |> Date.range(period_end_on)
          |> Enum.each(fn date ->
            report = build_report(state, date) |> Map.put(:status, "closed")

            %FinanceReportSnapshot{}
            |> FinanceReportSnapshot.changeset(%{
              report_on: date,
              data_json: Jason.encode!(report)
            })
            |> Repo.insert!()
          end)

          state
          |> FinanceReportingState.changeset(%{latest_close_on: period_end_on})
          |> Repo.update!()

          :ok
        else
          {:error, :invalid_period}
        end
    end
  end

  def record_event(operation_id, posting_on, attrs) do
    attrs =
      Map.merge(zero_movements(), attrs)
      |> Map.put_new(:late_adjustment, false)

    if Enum.any?(@cash_fields ++ @credit_fields, &(Map.get(attrs, &1, 0) != 0)) do
      %FinanceEvent{}
      |> FinanceEvent.changeset(
        Map.put(attrs, :operation_id, operation_id)
        |> Map.put(:posting_on, posting_on)
      )
      |> Repo.insert!()
    end

    :ok
  end

  def daily_report(date) do
    case Repo.one(from(state in FinanceReportingState)) do
      nil ->
        {:error, :report_not_available}

      state ->
        if Date.compare(date, state.starts_on) == :lt do
          {:error, :report_not_available}
        else
          case Repo.one(
                 from snapshot in FinanceReportSnapshot, where: snapshot.report_on == ^date
               ) do
            nil -> {:ok, build_report(state, date)}
            snapshot -> {:ok, Jason.decode!(snapshot.data_json)}
          end
        end
    end
  end

  defp build_report(state, date) do
    events =
      Repo.all(
        from event in FinanceEvent,
          where: event.posting_on < ^date,
          order_by: [asc: event.id]
      )

    daily_events =
      Repo.all(
        from event in FinanceEvent,
          where: event.posting_on == ^date,
          order_by: [asc: event.id]
      )

    ordinary_daily_events = Enum.reject(daily_events, & &1.late_adjustment)
    late_daily_events = Enum.filter(daily_events, & &1.late_adjustment)
    inception_cash = Jason.decode!(state.opening_cash_json)
    prior_cash_movements = cash_movements(events)
    daily_cash_movements = cash_movements(ordinary_daily_events)
    late_cash_movements = cash_movements(late_daily_events)

    properties =
      (Map.keys(inception_cash) ++
         Map.keys(prior_cash_movements) ++
         Map.keys(daily_cash_movements) ++
         Map.keys(late_cash_movements))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(fn property_id ->
        inception = Map.get(inception_cash, property_id, 0)
        prior = Map.get(prior_cash_movements, property_id, zero_cash_movements())
        opening = closing_cash(inception, prior)
        movement = Map.get(daily_cash_movements, property_id, zero_cash_movements())
        late_movement = Map.get(late_cash_movements, property_id, zero_cash_movements())
        closing = closing_cash(opening, add_cash_movement_maps(movement, late_movement))

        {property_id, opening, movement, late_movement, closing}
      end)
      |> Enum.reject(fn {_property_id, opening, movement, late_movement, closing} ->
        opening == 0 and closing == 0 and
          Enum.all?(Map.values(add_cash_movement_maps(movement, late_movement)), &(&1 == 0))
      end)
      |> Enum.map(fn {property_id, opening, movement, _late_movement, closing} ->
        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: movement,
          closing_held_cents: closing
        }
      end)

    prior_credit_movements =
      Enum.reduce(events, zero_credit_movements(), fn event, movements ->
        add_credit_movements(movements, event)
      end)
      |> Map.update!(:expired_cents, &(&1 + expired_credit_before(state.starts_on, date)))

    credit_opening = closing_credit(state.opening_credit_liability_cents, prior_credit_movements)

    credit_movements =
      Enum.reduce(ordinary_daily_events, zero_credit_movements(), fn event, movements ->
        add_credit_movements(movements, event)
      end)
      |> Map.update!(:expired_cents, &(&1 + expired_credit_on(state.starts_on, date)))

    late_credit_movements =
      Enum.reduce(late_daily_events, zero_credit_movements(), fn event, movements ->
        add_credit_movements(movements, event)
      end)

    total_credit_movements = add_credit_movement_maps(credit_movements, late_credit_movements)

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: credit_opening,
        movements: credit_movements,
        closing_liability_cents: closing_credit(credit_opening, total_credit_movements)
      },
      late_adjustments: %{
        cash: late_adjustment_cash(late_cash_movements),
        credit: late_credit_movements
      }
    }
  end

  defp cash_movements(events) do
    Enum.reduce(events, %{}, fn event, movements ->
      if is_binary(event.property_id) do
        Map.update(
          movements,
          event.property_id,
          cash_movement_for_event(event),
          &add_cash_movements(&1, event)
        )
      else
        movements
      end
    end)
  end

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^as_of,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from allocation in GroupCreditAllocation,
          join: group in Group,
          on: group.id == allocation.group_record_id,
          where: group.status == "active" and allocation.status == "held",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + applied
  end

  defp expired_credit_before(starts_on, date) do
    Repo.all(
      from lot in CreditLot,
        where: lot.expires_on > ^starts_on and lot.expires_on < ^date,
        select: {lot.id, lot.remaining_cents, lot.expires_on, lot.source_operation_id}
    )
    |> Enum.reduce(0, &expired_lot_amount(&1, &2))
  end

  defp expired_credit_on(starts_on, date) do
    Repo.all(
      from lot in CreditLot,
        where: lot.expires_on > ^starts_on and lot.expires_on == ^date,
        select: {lot.id, lot.remaining_cents, lot.expires_on, lot.source_operation_id}
    )
    |> Enum.reduce(0, &expired_lot_amount(&1, &2))
  end

  defp expired_lot_amount(
         {lot_id, current_remaining, expires_on, source_operation_id},
         total
       ) do
    if late_issuance_after_expiry?(source_operation_id, expires_on) do
      total
    else
      balance_events =
        Repo.all(
          from event in CreditLotBalanceEvent,
            where: event.credit_lot_id == ^lot_id and event.occurred_on < ^expires_on,
            select: event.amount_cents
        )

      remaining_at_expiry =
        case balance_events do
          [] -> current_remaining
          amounts -> max(Enum.sum(amounts), 0)
        end

      total + remaining_at_expiry
    end
  end

  defp late_issuance_after_expiry?(source_operation_id, expires_on) do
    case Repo.one(
           from event in FinanceEvent,
             where:
               event.operation_id == ^source_operation_id and
                 event.issued_cents > 0,
             select: min(event.posting_on)
         ) do
      nil -> false
      posting_on -> Date.compare(posting_on, expires_on) != :lt
    end
  end

  defp cash_movement_for_event(event) do
    Map.new(@cash_fields, &{&1, Map.get(event, &1, 0)})
  end

  defp late_adjustment_cash(movements) do
    movements
    |> Enum.reject(fn {_property_id, movement} -> Enum.all?(Map.values(movement), &(&1 == 0)) end)
    |> Enum.sort_by(fn {property_id, _movement} -> property_id end)
    |> Enum.map(fn {property_id, movement} ->
      %{property_id: property_id, movements: movement}
    end)
  end

  defp zero_cash_movements, do: Map.new(@cash_fields, &{&1, 0})
  defp zero_credit_movements, do: Map.new(@credit_fields, &{&1, 0})
  defp zero_movements, do: Map.merge(zero_cash_movements(), zero_credit_movements())

  defp add_cash_movements(movements, event) do
    Enum.reduce(@cash_fields, movements, fn field, movements ->
      Map.update!(movements, field, &(&1 + Map.get(event, field, 0)))
    end)
  end

  defp add_cash_movement_maps(movements, additional) do
    Enum.reduce(@cash_fields, movements, fn field, movements ->
      Map.update!(movements, field, &(&1 + Map.get(additional, field, 0)))
    end)
  end

  defp add_credit_movements(movements, event) do
    Enum.reduce(@credit_fields, movements, fn field, movements ->
      Map.update!(movements, field, &(&1 + Map.get(event, field, 0)))
    end)
  end

  defp add_credit_movement_maps(movements, additional) do
    Enum.reduce(@credit_fields, movements, fn field, movements ->
      Map.update!(movements, field, &(&1 + Map.get(additional, field, 0)))
    end)
  end

  defp closing_cash(opening, movement) do
    opening + movement.received_cents + movement.transferred_in_cents -
      movement.transferred_out_cents - movement.refunded_cents - movement.retained_cents -
      movement.converted_to_credit_cents - movement.reduced_cents - movement.charged_back_cents
  end

  defp closing_credit(opening, movement) do
    opening + movement.issued_cents - movement.expired_cents - movement.consumed_cents -
      movement.revoked_cents - movement.absorbed_cents
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp max_date(nil, date), do: date

  defp max_date(date, starts_on),
    do: if(Date.compare(date, starts_on) == :lt, do: starts_on, else: date)
end
