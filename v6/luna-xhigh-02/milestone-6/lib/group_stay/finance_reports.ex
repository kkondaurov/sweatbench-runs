defmodule GroupStay.FinanceReports do
  import Ecto.Query

  alias GroupStay.FinanceEvent
  alias GroupStay.FinanceReporting
  alias GroupStay.FinanceReportingCreditOpening
  alias GroupStay.FinanceReportingOpening
  alias GroupStay.Repo

  @cash_fields ~w(
    received_cents
    transferred_in_cents
    transferred_out_cents
    refunded_cents
    retained_cents
    converted_to_credit_cents
    reduced_cents
    charged_back_cents
  )
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  def get(date) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        :not_available

      %{starts_on: starts_on} = reporting ->
        if Date.compare(date, starts_on) == :lt do
          :not_available
        else
          {:ok, build_report(reporting, date)}
        end
    end
  end

  defp build_report(reporting, date) do
    events =
      Repo.all(
        from event in FinanceEvent,
          where: event.posting_on <= ^date,
          order_by: [asc: event.posting_on, asc: event.id]
      )

    cash = build_cash(events)
    credit_movements = build_credit_movements(events, automatic_expiry(date, events))

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: reporting.opening_credit_liability_cents,
        movements: credit_movements,
        closing_liability_cents:
          reporting.opening_credit_liability_cents +
            credit_movements["issued_cents"] -
            credit_movements["expired_cents"] -
            credit_movements["consumed_cents"] -
            credit_movements["revoked_cents"] -
            credit_movements["absorbed_cents"]
      }
    }
  end

  defp build_cash(events) do
    opening =
      Repo.all(from row in FinanceReportingOpening, select: {row.property_id, row.held_cents})
      |> Map.new()

    movements =
      Enum.reduce(events, %{}, fn event, properties ->
        Enum.reduce(event.cash_movements || %{}, properties, fn {property_id, event_movements},
                                                                properties ->
          Enum.reduce(event_movements || %{}, properties, fn {field, amount}, properties ->
            update_property_movement(properties, property_id, field, amount)
          end)
        end)
      end)

    properties = (Map.keys(opening) ++ Map.keys(movements)) |> Enum.uniq() |> Enum.sort()

    Enum.reduce(properties, [], fn property_id, cash ->
      property_movements = normalize_movements(Map.get(movements, property_id, %{}), @cash_fields)
      opening_held = Map.get(opening, property_id, 0)

      closing_held =
        opening_held + property_movements["received_cents"] +
          property_movements["transferred_in_cents"] -
          property_movements["transferred_out_cents"] -
          property_movements["refunded_cents"] -
          property_movements["retained_cents"] -
          property_movements["converted_to_credit_cents"] -
          property_movements["reduced_cents"] -
          property_movements["charged_back_cents"]

      if opening_held == 0 and closing_held == 0 and
           Enum.all?(property_movements, fn {_field, amount} -> amount == 0 end) do
        cash
      else
        cash ++
          [
            %{
              property_id: property_id,
              opening_held_cents: opening_held,
              movements: property_movements,
              closing_held_cents: closing_held
            }
          ]
      end
    end)
  end

  defp build_credit_movements(events, automatic_expired) do
    movements =
      Enum.reduce(events, zero_movements(@credit_fields), fn event, movements ->
        Enum.reduce(event.credit_movements || %{}, movements, fn {field, amount}, movements ->
          if field in @credit_fields do
            Map.update(movements, field, amount, &(&1 + amount))
          else
            movements
          end
        end)
      end)

    Map.update(movements, "expired_cents", automatic_expired, &(&1 + automatic_expired))
  end

  defp automatic_expiry(date, events) do
    states =
      Repo.all(from row in FinanceReportingCreditOpening, select: row)
      |> Map.new(fn row ->
        {row.lot_id,
         %{
           available_cents: row.available_cents,
           applied_cents: row.applied_cents,
           expires_on: row.expires_on
         }}
      end)

    {states, expired} =
      Enum.reduce(events, {states, 0}, fn event, {states, expired} ->
        {states, event_expiry} = expire_before_event(states, event.posting_on, date)
        {apply_lot_changes(states, event.credit_lot_changes || %{}), expired + event_expiry}
      end)

    {_states, expired_after} = expire_all(states, date)
    expired + expired_after
  end

  defp expire_before_event(states, posting_on, report_date) do
    if Date.compare(posting_on, report_date) == :gt do
      {states, 0}
    else
      expire_all(states, posting_on)
    end
  end

  defp expire_all(states, date) do
    Enum.reduce(states, {%{}, 0}, fn {lot_id, state}, {next_states, expired} ->
      if state.available_cents > 0 and Date.compare(state.expires_on, date) != :gt do
        {Map.put(next_states, lot_id, %{state | available_cents: 0}),
         expired + state.available_cents}
      else
        {Map.put(next_states, lot_id, state), expired}
      end
    end)
  end

  defp apply_lot_changes(states, changes) do
    Enum.reduce(changes, states, fn {lot_id, change}, states ->
      lot_id = parse_integer_key(lot_id)

      state =
        Map.get(states, lot_id, %{
          available_cents: 0,
          applied_cents: 0,
          expires_on: parse_date!(change["expires_on"])
        })

      Map.put(states, lot_id, %{
        state
        | available_cents: state.available_cents + (change["available_delta"] || 0),
          applied_cents: state.applied_cents + (change["applied_delta"] || 0),
          expires_on: parse_date!(change["expires_on"])
      })
    end)
  end

  defp update_property_movement(properties, property_id, field, amount) do
    Map.update(properties, property_id, %{field => amount}, fn movements ->
      Map.update(movements, field, amount, &(&1 + amount))
    end)
  end

  defp normalize_movements(movements, fields),
    do: Map.new(fields, &{&1, Map.get(movements, &1, 0)})

  defp zero_movements(fields), do: Map.new(fields, &{&1, 0})

  defp parse_integer_key(key) when is_integer(key), do: key
  defp parse_integer_key(key), do: String.to_integer(key)

  defp parse_date!(date) do
    {:ok, parsed} = Date.from_iso8601(date)
    parsed
  end
end
