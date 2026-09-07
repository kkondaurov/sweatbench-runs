defmodule GroupStay.FinanceReporting.Report do
  @moduledoc """
  Folds the finance journal into the exact public representation for one day.

  Natural credit expiry is derived from the opening lot positions and signed
  lot deltas. This keeps reports read-only while still allowing a late,
  backdated operation to change an earlier open report.
  """

  import Ecto.Query

  alias GroupStay.FinanceReporting.{
    CashOpeningBalance,
    CreditLotOpeningBalance,
    OperationMovement,
    ReportingStart
  }

  alias GroupStay.Repo

  @cash_fields ~w(
    received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents
    converted_to_credit_cents reduced_cents charged_back_cents
  )
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  @doc false
  def build(%ReportingStart{} = start, date) do
    movements = Repo.all(from movement in OperationMovement, order_by: movement.inserted_at)
    expiries = natural_expiries(start, movements)

    %{
      date: date,
      status: "open",
      cash: cash_report(date, movements),
      credit: credit_report(date, start, movements, expiries)
    }
  end

  defp cash_report(date, movements) do
    opening =
      CashOpeningBalance
      |> Repo.all()
      |> Map.new(&{&1.property_id, &1.opening_held_cents})

    properties =
      Enum.reduce(movements, Map.keys(opening), fn movement, properties ->
        Map.keys(movement.cash) ++ properties
      end)

    properties
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      before_movements = cash_sum(movements, property_id, &Date.before?(&1.posting_date, date))
      day_movements = cash_sum(movements, property_id, &(&1.posting_date == date))
      opening_held = Map.get(opening, property_id, 0) + cash_net(before_movements)
      closing_held = opening_held + cash_net(day_movements)

      %{
        property_id: property_id,
        opening_held_cents: opening_held,
        movements: day_movements,
        closing_held_cents: closing_held
      }
    end)
    |> Enum.reject(fn entry ->
      entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
        all_zero?(entry.movements)
    end)
  end

  defp cash_sum(movements, property_id, include?) do
    Enum.reduce(movements, zero_cash_movements(), fn movement, totals ->
      if include?.(movement) do
        add_fields(totals, Map.get(movement.cash, property_id, %{}), @cash_fields)
      else
        totals
      end
    end)
  end

  defp credit_report(date, start, movements, expiries) do
    prior = credit_sum(movements, &Date.before?(&1.posting_date, date))
    current = credit_sum(movements, &(&1.posting_date == date))
    prior_expired = expiry_sum(expiries, &Date.before?(&1.date, date))
    current_expired = expiry_sum(expiries, &(&1.date == date))
    current = Map.update!(current, "expired_cents", &(&1 + current_expired))
    opening = start.opening_credit_liability_cents + credit_net(prior) - prior_expired

    %{
      opening_liability_cents: opening,
      movements: current,
      closing_liability_cents: opening + credit_net(current)
    }
  end

  defp credit_sum(movements, include?) do
    Enum.reduce(movements, zero_credit_movements(), fn movement, totals ->
      if include?.(movement),
        do: add_fields(totals, movement.credit, @credit_fields),
        else: totals
    end)
  end

  defp natural_expiries(start, movements) do
    openings =
      CreditLotOpeningBalance
      |> Repo.all()
      |> Map.new(fn balance ->
        {balance.credit_lot_record_id,
         %{
           expires_on: balance.expires_on,
           remaining_cents: balance.remaining_cents,
           allocated_cents: balance.allocated_cents
         }}
      end)

    deltas =
      Enum.flat_map(movements, fn movement ->
        Enum.map(
          movement.credit_lot_deltas["entries"],
          &Map.put(&1, "posting_date", movement.posting_date)
        )
      end)

    lot_ids =
      (Map.keys(openings) ++ Enum.map(deltas, & &1["credit_lot_record_id"]))
      |> Enum.uniq()

    Enum.flat_map(lot_ids, fn lot_id ->
      lot_deltas = Enum.filter(deltas, &(&1["credit_lot_record_id"] == lot_id))
      opening = Map.get(openings, lot_id)

      expires_on =
        if opening,
          do: opening.expires_on,
          else: lot_deltas |> hd() |> Map.fetch!("expires_on") |> Date.from_iso8601!()

      expiry_date = Date.add(expires_on, 1)

      if Date.compare(expiry_date, start.starts_on) == :gt do
        initial = opening || %{remaining_cents: 0, allocated_cents: 0}

        at_expiry =
          Enum.reduce(lot_deltas, initial, fn delta, state ->
            if Date.compare(delta["posting_date"], expires_on) in [:lt, :eq] do
              %{
                state
                | remaining_cents: state.remaining_cents + delta["remaining_cents"],
                  allocated_cents: state.allocated_cents + delta["allocated_cents"]
              }
            else
              state
            end
          end)

        amount = max(at_expiry.remaining_cents - at_expiry.allocated_cents, 0)
        if amount == 0, do: [], else: [%{date: expiry_date, amount_cents: amount}]
      else
        []
      end
    end)
  end

  defp expiry_sum(expiries, include?) do
    expiries
    |> Enum.filter(include?)
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end

  defp cash_net(movements) do
    movements["received_cents"] + movements["transferred_in_cents"] -
      movements["transferred_out_cents"] - movements["refunded_cents"] -
      movements["retained_cents"] - movements["converted_to_credit_cents"] -
      movements["reduced_cents"] - movements["charged_back_cents"]
  end

  defp credit_net(movements) do
    movements["issued_cents"] - movements["expired_cents"] - movements["consumed_cents"] -
      movements["revoked_cents"] - movements["absorbed_cents"]
  end

  defp add_fields(left, right, fields) do
    Map.new(fields, fn field -> {field, left[field] + Map.get(right, field, 0)} end)
  end

  defp zero_cash_movements, do: Map.new(@cash_fields, &{&1, 0})
  defp zero_credit_movements, do: Map.new(@credit_fields, &{&1, 0})
  defp all_zero?(movements), do: Enum.all?(movements, fn {_field, amount} -> amount == 0 end)
end
