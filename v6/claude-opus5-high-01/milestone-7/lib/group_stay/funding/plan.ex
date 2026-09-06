defmodule GroupStay.Funding.Plan do
  @moduledoc """
  The pure arithmetic behind room-level funding.

  Cash and hotel credit fill active room deposits in the rooms' original order,
  filling one room before moving to the next. Funding that predates durable
  operation records is carried forward as a single unattributed senior block that
  fills rooms ahead of everything a record can account for.
  """

  @doc """
  Spreads `amount_cents` over `capacities`, in order, filling each entry before
  moving to the next.

  Returns `{placements, unplaced_cents}` where `placements` holds one
  `{index, amount_cents}` pair per capacity that receives something.
  """
  def fill(capacities, amount_cents) do
    {placements, unplaced} =
      capacities
      |> Enum.with_index()
      |> Enum.reduce({[], amount_cents}, fn {capacity, index}, {placements, left} ->
        case min(max(capacity, 0), left) do
          0 -> {placements, left}
          taken -> {[{index, taken} | placements], left - taken}
        end
      end)

    {Enum.reverse(placements), unplaced}
  end

  @doc """
  Orders the funding a group already holds into the sequence room allocation
  follows.

  `records` are the group's applied funding operations in durable-record commit
  order, each `%{operation_id: id, kind: :cash | :credit, amount_cents: n}`.
  `redemptions` are the group's credit redemptions as `{lot_ref, amount_cents}`
  in their original consumption order. Whatever `cash_cents` and `credit_cents`
  the records cannot account for is the unattributed senior block, which comes
  first: its aggregate cash, then its credit lots.

  Returns funding events as
  `%{kind:, operation_id:, lot_ref:, amount_cents:}`, senior block first.
  """
  def carry_forward(cash_cents, credit_cents, records, redemptions) do
    senior_cash = max(cash_cents - recorded(records, :cash), 0)
    senior_credit = max(credit_cents - recorded(records, :credit), 0)

    {senior_credit_events, redemptions} = take_credit(redemptions, senior_credit, nil)

    {recorded_events, _left} =
      Enum.flat_map_reduce(records, redemptions, fn record, redemptions ->
        case record.kind do
          :cash -> {[cash_event(record.operation_id, record.amount_cents)], redemptions}
          :credit -> take_credit(redemptions, record.amount_cents, record.operation_id)
        end
      end)

    senior_cash_events = if senior_cash > 0, do: [cash_event(nil, senior_cash)], else: []

    senior_cash_events ++ senior_credit_events ++ recorded_events
  end

  defp recorded(records, kind) do
    records
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  defp cash_event(operation_id, amount_cents) do
    %{kind: :cash, operation_id: operation_id, lot_ref: nil, amount_cents: amount_cents}
  end

  defp take_credit(redemptions, 0, _operation_id), do: {[], redemptions}
  defp take_credit([], _amount_cents, _operation_id), do: {[], []}

  defp take_credit([{lot_ref, available} | rest], amount_cents, operation_id) do
    taken = min(available, amount_cents)
    left_in_lot = available - taken
    rest = if left_in_lot > 0, do: [{lot_ref, left_in_lot} | rest], else: rest

    event = %{
      kind: :credit,
      operation_id: operation_id,
      lot_ref: lot_ref,
      amount_cents: taken
    }

    {events, redemptions} = take_credit(rest, amount_cents - taken, operation_id)

    {[event | events], redemptions}
  end
end
