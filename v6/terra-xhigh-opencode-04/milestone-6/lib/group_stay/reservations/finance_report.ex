defmodule GroupStay.Reservations.FinanceReport do
  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashRoomAllocation,
    CreditApplication,
    CreditLot,
    FinanceEvent,
    FinanceOpeningCash,
    FinanceOpeningCreditLot,
    FinanceReporting,
    Group,
    Room
  }

  @cash_event_types [
    "cash_received",
    "cash_transferred_in",
    "cash_transferred_out",
    "cash_refunded",
    "cash_retained",
    "cash_converted_to_credit",
    "cash_reduced",
    "cash_charged_back"
  ]
  @credit_event_types [
    "credit_issued",
    "credit_expired",
    "credit_consumed",
    "credit_revoked",
    "credit_absorbed",
    "credit_state"
  ]

  def start(operation_id, starts_on) do
    if Repo.get(FinanceReporting, 1) do
      {:error, :already_started}
    else
      case Repo.insert(
             FinanceReporting.changeset(%FinanceReporting{id: 1}, %{
               starts_on: starts_on,
               operation_id: operation_id,
               opening_credit_liability_cents: 0
             })
           ) do
        {:ok, reporting} ->
          snapshot_opening_cash!(reporting)
          opening_credit_liability_cents = snapshot_opening_credit!(reporting, starts_on)

          reporting =
            reporting
            |> FinanceReporting.changeset(%{
              opening_credit_liability_cents: opening_credit_liability_cents
            })
            |> Repo.update!()

          {:ok, reporting}

        {:error, _changeset} ->
          {:error, :already_started}
      end
    end
  end

  def record_cash(operation_id, occurred_on, event_type, property_id, amount_cents)
      when amount_cents != 0 do
    with %FinanceReporting{} = reporting <- Repo.get(FinanceReporting, 1) do
      insert_event!(reporting, %{
        operation_id: operation_id,
        posting_on: posting_on(occurred_on, reporting.starts_on),
        event_type: event_type,
        property_id: property_id,
        amount_cents: amount_cents
      })
    end

    :ok
  end

  def record_cash(_operation_id, _occurred_on, _event_type, _property_id, _amount_cents), do: :ok

  def record_credit(
        operation_id,
        occurred_on,
        event_type,
        amount_cents,
        credit_lot,
        available_delta_cents \\ 0,
        applied_delta_cents \\ 0
      ) do
    with %FinanceReporting{} = reporting <- Repo.get(FinanceReporting, 1) do
      insert_event!(reporting, %{
        operation_id: operation_id,
        posting_on: posting_on(occurred_on, reporting.starts_on),
        event_type: event_type,
        amount_cents: amount_cents,
        credit_lot_id: credit_lot && credit_lot.id,
        credit_lot_expires_on: credit_lot && credit_lot.expires_on,
        available_delta_cents: available_delta_cents,
        applied_delta_cents: applied_delta_cents
      })
    end

    :ok
  end

  def daily_report(date) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        {:error, :report_not_available}

      %FinanceReporting{starts_on: starts_on} when date < starts_on ->
        {:error, :report_not_available}

      %FinanceReporting{} = reporting ->
        {:ok,
         %{
           date: Date.to_iso8601(date),
           status: "open",
           cash: cash_report(reporting, date),
           credit: credit_report(reporting, date)
         }}
    end
  end

  defp snapshot_opening_cash!(reporting) do
    Repo.all(
      from allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.id == room.group_id,
        where: room.status == "active",
        group_by: group.property_id,
        select: {group.property_id, sum(allocation.amount_cents)}
    )
    |> Enum.each(fn {property_id, opening_held_cents} ->
      Repo.insert!(
        FinanceOpeningCash.changeset(%FinanceOpeningCash{}, %{
          finance_reporting_id: reporting.id,
          property_id: property_id,
          opening_held_cents: opening_held_cents
        })
      )
    end)
  end

  defp snapshot_opening_credit!(reporting, starts_on) do
    CreditLot
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      applied_cents = active_applied_credit(lot.id)

      opening_available_cents =
        if Date.compare(lot.expires_on, starts_on) == :gt, do: lot.remaining_cents, else: 0

      if opening_available_cents > 0 or applied_cents > 0 do
        Repo.insert!(
          FinanceOpeningCreditLot.changeset(%FinanceOpeningCreditLot{}, %{
            finance_reporting_id: reporting.id,
            credit_lot_id: lot.id,
            expires_on: lot.expires_on,
            opening_available_cents: opening_available_cents
          })
        )
      end

      total + opening_available_cents + applied_cents
    end)
  end

  defp active_applied_credit(credit_lot_id) do
    Repo.one(
      from application in CreditApplication,
        join: room in Room,
        on: room.id == application.room_id,
        where: application.credit_lot_id == ^credit_lot_id and room.status == "active",
        select: coalesce(sum(application.amount_cents), 0)
    )
  end

  defp insert_event!(reporting, attrs) do
    attrs =
      Map.merge(
        %{
          finance_reporting_id: reporting.id,
          property_id: nil,
          credit_lot_id: nil,
          credit_lot_expires_on: nil,
          available_delta_cents: 0,
          applied_delta_cents: 0
        },
        attrs
      )

    Repo.insert!(FinanceEvent.changeset(%FinanceEvent{}, attrs))
  end

  defp posting_on(occurred_on, starts_on) do
    if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
  end

  defp cash_report(reporting, date) do
    opening =
      Repo.all(
        from cash in FinanceOpeningCash,
          where: cash.finance_reporting_id == ^reporting.id,
          select: {cash.property_id, cash.opening_held_cents}
      )
      |> Map.new()

    events =
      Repo.all(
        from event in FinanceEvent,
          where:
            event.finance_reporting_id == ^reporting.id and
              event.event_type in ^@cash_event_types and event.posting_on <= ^date,
          order_by: [asc: event.posting_on, asc: event.id]
      )

    properties =
      Enum.reduce(events, opening, fn event, totals ->
        if event.posting_on < date do
          Map.update(totals, event.property_id, cash_effect(event), &(&1 + cash_effect(event)))
        else
          Map.put_new(totals, event.property_id, 0)
        end
      end)

    daily_movements =
      Enum.reduce(events, %{}, fn event, movements ->
        if event.posting_on == date do
          Map.update(
            movements,
            event.property_id,
            Map.update!(
              empty_cash_movements(),
              cash_movement_key(event.event_type),
              &(&1 + event.amount_cents)
            ),
            fn property_movements ->
              Map.update!(
                property_movements,
                cash_movement_key(event.event_type),
                &(&1 + event.amount_cents)
              )
            end
          )
        else
          movements
        end
      end)

    properties
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      opening_held_cents = Map.fetch!(properties, property_id)
      movements = Map.get(daily_movements, property_id, empty_cash_movements())
      closing_held_cents = opening_held_cents + cash_movement_effect(movements)

      %{
        property_id: property_id,
        opening_held_cents: opening_held_cents,
        movements: movements,
        closing_held_cents: closing_held_cents
      }
    end)
    |> Enum.reject(fn entry ->
      entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
        Enum.all?(entry.movements, fn {_key, value} -> value == 0 end)
    end)
  end

  defp credit_report(reporting, date) do
    opening_lots =
      Repo.all(
        from lot in FinanceOpeningCreditLot,
          where: lot.finance_reporting_id == ^reporting.id
      )

    events =
      Repo.all(
        from event in FinanceEvent,
          where:
            event.finance_reporting_id == ^reporting.id and
              event.event_type in ^@credit_event_types and event.posting_on <= ^date,
          order_by: [asc: event.posting_on, asc: event.id]
      )

    initial_state =
      Map.new(opening_lots, fn lot ->
        {lot.credit_lot_id,
         %{available_cents: lot.opening_available_cents, expires_on: lot.expires_on}}
      end)

    dates =
      (Enum.map(events, & &1.posting_on) ++
         Enum.map(opening_lots, & &1.expires_on) ++
         Enum.map(events, & &1.credit_lot_expires_on))
      |> Enum.filter(&(&1 && Date.compare(&1, date) != :gt))
      |> Enum.uniq()
      |> Enum.sort(Date)

    {prior_net, movements, _state} =
      Enum.reduce(dates, {0, empty_credit_movements(), initial_state}, fn event_date,
                                                                          {prior_net, movements,
                                                                           state} ->
        {state, event_movements} = apply_credit_events(state, events, event_date)
        {state, expired_cents} = expire_credit_lots(state, event_date)

        event_movements = Map.update!(event_movements, :expired_cents, &(&1 + expired_cents))
        net = credit_movement_effect(event_movements)

        if event_date < date do
          {prior_net + net, movements, state}
        else
          {prior_net, add_credit_movements(movements, event_movements), state}
        end
      end)

    opening_liability_cents = reporting.opening_credit_liability_cents + prior_net
    closing_liability_cents = opening_liability_cents + credit_movement_effect(movements)

    %{
      opening_liability_cents: opening_liability_cents,
      movements: movements,
      closing_liability_cents: closing_liability_cents
    }
  end

  defp apply_credit_events(state, events, event_date) do
    Enum.filter(events, &(&1.posting_on == event_date))
    |> Enum.reduce({state, empty_credit_movements()}, fn event, {state, movements} ->
      state = apply_credit_state(state, event)

      movements =
        case credit_movement_key(event.event_type) do
          nil -> movements
          key -> Map.update!(movements, key, &(&1 + event.amount_cents))
        end

      {state, movements}
    end)
  end

  defp apply_credit_state(state, %FinanceEvent{credit_lot_id: nil}), do: state

  defp apply_credit_state(state, event) do
    lot =
      Map.get(state, event.credit_lot_id, %{
        available_cents: 0,
        expires_on: event.credit_lot_expires_on
      })

    Map.put(state, event.credit_lot_id, %{
      lot
      | available_cents: max(lot.available_cents + event.available_delta_cents, 0),
        expires_on:
          effective_expiry(event.credit_lot_expires_on, event.posting_on, lot.expires_on)
    })
  end

  defp effective_expiry(nil, _posting_on, expires_on), do: expires_on

  defp effective_expiry(expires_on, posting_on, _previous_expiry) do
    if Date.compare(expires_on, posting_on) == :lt, do: posting_on, else: expires_on
  end

  defp expire_credit_lots(state, date) do
    Enum.reduce(state, {%{}, 0}, fn {lot_id, lot}, {updated_state, expired_cents} ->
      if lot.expires_on == date do
        {Map.put(updated_state, lot_id, %{lot | available_cents: 0}),
         expired_cents + lot.available_cents}
      else
        {Map.put(updated_state, lot_id, lot), expired_cents}
      end
    end)
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

  defp cash_movement_key("cash_received"), do: :received_cents
  defp cash_movement_key("cash_transferred_in"), do: :transferred_in_cents
  defp cash_movement_key("cash_transferred_out"), do: :transferred_out_cents
  defp cash_movement_key("cash_refunded"), do: :refunded_cents
  defp cash_movement_key("cash_retained"), do: :retained_cents
  defp cash_movement_key("cash_converted_to_credit"), do: :converted_to_credit_cents
  defp cash_movement_key("cash_reduced"), do: :reduced_cents
  defp cash_movement_key("cash_charged_back"), do: :charged_back_cents

  defp cash_effect(event) do
    case event.event_type do
      "cash_received" -> event.amount_cents
      "cash_transferred_in" -> event.amount_cents
      _ -> -event.amount_cents
    end
  end

  defp cash_movement_effect(movements) do
    movements.received_cents + movements.transferred_in_cents - movements.transferred_out_cents -
      movements.refunded_cents - movements.retained_cents - movements.converted_to_credit_cents -
      movements.reduced_cents - movements.charged_back_cents
  end

  defp credit_movement_key("credit_issued"), do: :issued_cents
  defp credit_movement_key("credit_expired"), do: :expired_cents
  defp credit_movement_key("credit_consumed"), do: :consumed_cents
  defp credit_movement_key("credit_revoked"), do: :revoked_cents
  defp credit_movement_key("credit_absorbed"), do: :absorbed_cents
  defp credit_movement_key("credit_state"), do: nil

  defp credit_movement_effect(movements) do
    movements.issued_cents - movements.expired_cents - movements.consumed_cents -
      movements.revoked_cents - movements.absorbed_cents
  end

  defp add_credit_movements(left, right) do
    Map.new(left, fn {key, value} -> {key, value + Map.fetch!(right, key)} end)
  end
end
