defmodule GroupStay.FinanceReporting do
  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CreditLot,
    CreditLotBalanceEvent,
    FinanceEvent,
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

  def record_event(operation_id, posting_on, attrs) do
    attrs = Map.merge(zero_movements(), attrs)

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
          {:ok, build_report(state, date)}
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

    inception_cash = Jason.decode!(state.opening_cash_json)
    prior_cash_movements = cash_movements(events)
    daily_cash_movements = cash_movements(daily_events)

    properties =
      (Map.keys(inception_cash) ++
         Map.keys(prior_cash_movements) ++ Map.keys(daily_cash_movements))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(fn property_id ->
        inception = Map.get(inception_cash, property_id, 0)
        prior = Map.get(prior_cash_movements, property_id, zero_cash_movements())
        opening = closing_cash(inception, prior)
        movement = Map.get(daily_cash_movements, property_id, zero_cash_movements())
        closing = closing_cash(opening, movement)

        {property_id, opening, movement, closing}
      end)
      |> Enum.reject(fn {_property_id, opening, movement, closing} ->
        opening == 0 and closing == 0 and Enum.all?(Map.values(movement), &(&1 == 0))
      end)
      |> Enum.map(fn {property_id, opening, movement, closing} ->
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
      Enum.reduce(daily_events, zero_credit_movements(), fn event, movements ->
        add_credit_movements(movements, event)
      end)
      |> Map.update!(:expired_cents, &(&1 + expired_credit_on(state.starts_on, date)))

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: credit_opening,
        movements: credit_movements,
        closing_liability_cents: closing_credit(credit_opening, credit_movements)
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
        select: {lot.id, lot.remaining_cents, lot.expires_on}
    )
    |> Enum.reduce(0, &expired_lot_amount(&1, &2))
  end

  defp expired_credit_on(starts_on, date) do
    Repo.all(
      from lot in CreditLot,
        where: lot.expires_on > ^starts_on and lot.expires_on == ^date,
        select: {lot.id, lot.remaining_cents, lot.expires_on}
    )
    |> Enum.reduce(0, &expired_lot_amount(&1, &2))
  end

  defp expired_lot_amount({lot_id, current_remaining, expires_on}, total) do
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

  defp cash_movement_for_event(event) do
    Map.new(@cash_fields, &{&1, Map.get(event, &1, 0)})
  end

  defp zero_cash_movements, do: Map.new(@cash_fields, &{&1, 0})
  defp zero_credit_movements, do: Map.new(@credit_fields, &{&1, 0})
  defp zero_movements, do: Map.merge(zero_cash_movements(), zero_credit_movements())

  defp add_cash_movements(movements, event) do
    Enum.reduce(@cash_fields, movements, fn field, movements ->
      Map.update!(movements, field, &(&1 + Map.get(event, field, 0)))
    end)
  end

  defp add_credit_movements(movements, event) do
    Enum.reduce(@credit_fields, movements, fn field, movements ->
      Map.update!(movements, field, &(&1 + Map.get(event, field, 0)))
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
