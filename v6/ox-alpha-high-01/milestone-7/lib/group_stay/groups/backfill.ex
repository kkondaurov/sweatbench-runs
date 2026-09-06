defmodule GroupStay.Groups.Backfill do
  @moduledoc """
  Rebuilds the room-accounting projections for databases created before this
  release.

  Groups funded before durable operation records existed have aggregate
  balances but no per-payment history. This module derives, per group:

  - the unattributed senior block: aggregate cash not explained by any applied
    durable cash payment, allocated first; then legacy hotel-credit
    applications in original consumption order;
  - allocations for funding represented by durable operation records, ordered
    by durable-record commit order regardless of `occurred_on`;
  - one `CashPayment` row per durably recorded applied cash payment, with
    dispositions derived from the group's stored settlement aggregates;
  - credit-lot entitlements for cash those payments converted into hotel
    credit when a durable cancellation settled them.

  No aggregate cash, credit, or liability balance is changed.
  """

  import Ecto.Query

  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.CashPayment
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.GroupCreditApplication
  alias GroupStay.Groups.LotEntitlement
  alias GroupStay.Groups.OperationRecord
  alias GroupStay.Repo

  @flexible_deposit_percent 20
  @credit_bonus_percent 10

  def run do
    Repo.delete_all(Allocation)
    Repo.delete_all(LotEntitlement)
    Repo.delete_all(CashPayment)

    Enum.each(Repo.all(Group), &backfill_group/1)
  end

  defp backfill_group(group) do
    ops = applied_group_ops(group.group_id)
    cash_ops = Enum.filter(ops, &(&1.type == "record_cash_payment"))
    cancel_op = Enum.find(ops, &(&1.type == "cancel_group"))

    cond do
      cancel_op -> backfill_cancelled(group, cash_ops, cancel_op)
      group.status == "active" -> backfill_active(group, ops)
      true -> :ok
    end
  end

  # -- Active groups: rebuild room allocations ---------------------------------

  defp backfill_active(group, ops) do
    cash_ops = Enum.filter(ops, &(&1.type == "record_cash_payment"))
    credit_ops = Enum.filter(ops, &(&1.type == "apply_hotel_credit"))

    legacy_cash =
      max(group.cash_paid_cents - sum_result_amounts(cash_ops), 0)

    legacy_credit =
      max(group.credit_applied_cents - sum_result_amounts(credit_ops), 0)

    applications = consumption_stream(group)

    # The unattributed senior block: aggregate cash first, then legacy
    # hotel-credit lots in original consumption order.
    {legacy_units, rest_stream} =
      consume_units(applications, legacy_credit)

    legacy_units =
      Enum.concat([
        [{legacy_cash, %{kind: "cash", payment_operation_id: nil, credit_lot_id: nil}}],
        Enum.map(legacy_units, fn {lot_id, amount} ->
          {amount, %{kind: "credit", payment_operation_id: nil, credit_lot_id: lot_id}}
        end)
      ])

    # Durable funding in commit order, classified by retained operation type.
    {durable_units, rest_stream} =
      Enum.reduce(ops, {[], rest_stream}, fn
        %OperationRecord{type: "record_cash_payment"} = op, {units, stream} ->
          unit = %{kind: "cash", payment_operation_id: op.operation_id, credit_lot_id: nil}
          {units ++ [{result_amount(op), unit}], stream}

        %OperationRecord{type: "apply_hotel_credit"} = op, {units, stream} ->
          {taken, rest} = consume_units(stream, result_amount(op))

          units =
            units ++
              Enum.map(taken, fn {lot_id, amount} ->
                {amount, %{kind: "credit", payment_operation_id: nil, credit_lot_id: lot_id}}
              end)

          {units, rest}

        _op, acc ->
          acc
      end)

    # Anything left in the consumption stream is unattributed legacy credit;
    # keep aggregate balances intact by allocating it last.
    trailing_units =
      Enum.map(rest_stream, fn {lot_id, amount} ->
        {amount, %{kind: "credit", payment_operation_id: nil, credit_lot_id: lot_id}}
      end)

    units = Enum.concat([legacy_units, durable_units, trailing_units])

    rows =
      units
      |> Enum.reduce({0, []}, fn {amount, unit_attrs}, {position, rows} ->
        {rows_for_unit, _rooms_left} = fill_rooms(room_balances(group), amount)

        allocs =
          Enum.map(rows_for_unit, fn {room_id, taken} ->
            %{
              group_id: group.id,
              room_id: room_id,
              position: position,
              kind: unit_attrs.kind,
              payment_operation_id: unit_attrs.payment_operation_id,
              credit_lot_id: unit_attrs.credit_lot_id,
              amount_cents: taken
            }
          end)

        {position + 1, rows ++ allocs}
      end)
      |> elem(1)

    Enum.each(rows, &Repo.insert!(struct(Allocation, &1)))

    Enum.each(cash_ops, fn op ->
      amount = result_amount(op)

      Repo.insert!(%CashPayment{
        operation_id: op.operation_id,
        group_id: group.id,
        amount_cents: amount,
        held_cents: amount
      })
    end)
  end

  defp room_balances(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.map(group.rooms, fn room ->
      lodging = room.nightly_rate_cents * nights
      deposit = room_deposit(lodging, group.rate_plan)
      %{room_id: room.room_id, outstanding: deposit}
    end)
  end

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  defp room_deposit(lodging_cents, "flexible"),
    do: percent_half_up(lodging_cents, @flexible_deposit_percent)

  # Fills rooms in their original order, exhausting one room's deposit before
  # moving to the next. Returns `{[{room_id, amount}], remaining_rooms}`.
  defp fill_rooms(rooms, amount, taken \\ [])

  defp fill_rooms([], _amount, taken), do: {Enum.reverse(taken), []}

  defp fill_rooms([room | rest], amount, taken) do
    take = min(max(amount, 0), room.outstanding)

    {rows, left} =
      if take > 0 do
        fill_rooms(rest, amount - take, [{room.room_id, take} | taken])
      else
        fill_rooms(rest, amount, taken)
      end

    {rows, [%{room_id: room.room_id, outstanding: room.outstanding - take} | left]}
  end

  # -- Cancelled groups: rebuild payment dispositions ---------------------------

  defp backfill_cancelled(group, cash_ops, cancel_op) do
    outcome =
      cond do
        cancel_op.result["refunded_cents"] > 0 -> :refunded
        cancel_op.result["credit_issued_cents"] > 0 -> :converted
        true -> :retained
      end

    Enum.each(cash_ops, fn op ->
      amount = result_amount(op)

      Repo.insert!(%CashPayment{
        operation_id: op.operation_id,
        group_id: group.id,
        amount_cents: amount,
        held_cents: 0,
        refunded_cents: if(outcome == :refunded, do: amount, else: 0),
        retained_cents: if(outcome == :retained, do: amount, else: 0),
        converted_to_credit_cents: if(outcome == :converted, do: amount, else: 0)
      })
    end)

    if outcome == :converted do
      case Repo.get_by(CreditLot, source_operation_id: cancel_op.operation_id) do
        nil ->
          :ok

        lot ->
          recorded_cash = sum_result_amounts(cash_ops)
          legacy_cash = max(group.cash_paid_cents - recorded_cash, 0)

          contributors =
            Enum.concat([
              [{nil, legacy_cash}],
              Enum.map(cash_ops, fn op -> {op.operation_id, result_amount(op)} end)
            ])

          insert_entitlements(lot, contributors)
      end
    end
  end

  # Each contributor's entitlement telescopes: the rounded bonus value of the
  # settled cash through it minus the bonus value through its predecessor.
  defp insert_entitlements(lot, contributors) do
    Enum.reduce(contributors, 0, fn {payment_operation_id, principal}, run ->
      new_run = run + principal
      bonus_percent = 100 + @credit_bonus_percent

      entitled =
        percent_half_up(new_run, bonus_percent) - percent_half_up(run, bonus_percent)

      if is_binary(payment_operation_id) and entitled > 0 do
        Repo.insert!(%LotEntitlement{
          credit_lot_id: lot.id,
          payment_operation_id: payment_operation_id,
          principal_cents: principal,
          entitled_cents: entitled,
          unrecovered_clawback_cents: 0
        })
      end

      new_run
    end)

    :ok
  end

  # -- Shared helpers ------------------------------------------------------------

  # Applied durable operations addressed to a group, in commit order.
  defp applied_group_ops(group_id) do
    from(r in OperationRecord,
      where:
        fragment("json_extract(?, '$.status')", r.result) == "applied" and
          fragment("json_extract(?, '$.group_id')", r.result) == ^group_id,
      order_by: [asc: r.id]
    )
    |> Repo.all()
  end

  defp result_amount(%OperationRecord{result: result}),
    do: result["amount_cents"] || 0

  defp sum_result_amounts(ops), do: Enum.sum(Enum.map(ops, &result_amount/1))

  # The group's credit applications in original consumption order: earliest
  # expiry first, then source operation identifier. Consumption was greedy over
  # monotonically decreasing balances, so this reproduces the historical order.
  defp consumption_stream(group) do
    from(a in GroupCreditApplication,
      join: l in CreditLot,
      on: l.id == a.credit_lot_id,
      where: a.group_id == ^group.id,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: a.inserted_at],
      select: {a.credit_lot_id, a.amount_cents}
    )
    |> Repo.all()
  end

  # Takes `amount` cents from the front of a consumption stream, merging
  # adjacent portions of the same lot into single units. Returns
  # `{[{lot_id, amount}], remaining_stream}`.
  defp consume_units(stream, amount) do
    {taken_rev, rest} = take_amount(stream, amount, [])
    {merge_consecutive(Enum.reverse(taken_rev)), rest}
  end

  defp take_amount(stream, amount, taken) when amount <= 0, do: {taken, stream}

  defp take_amount([{lot_id, row_amount} | rest], amount, taken) do
    portion = min(row_amount, amount)

    if portion >= row_amount do
      take_amount(rest, amount - portion, [{lot_id, portion} | taken])
    else
      {[{lot_id, portion} | taken], [{lot_id, row_amount - portion} | rest]}
    end
  end

  defp take_amount([], _amount, taken), do: {taken, []}

  defp merge_consecutive([]), do: []

  defp merge_consecutive([{lot_id, amount} | rest]) do
    merge_consecutive(rest, lot_id, amount, [])
  end

  defp merge_consecutive([], lot_id, amount, acc), do: Enum.reverse([{lot_id, amount} | acc])

  defp merge_consecutive([{lot_id, amount} | rest], lot_id, running, acc) do
    merge_consecutive(rest, lot_id, running + amount, acc)
  end

  defp merge_consecutive([{other, amount} | rest], lot_id, running, acc) do
    merge_consecutive(rest, other, amount, [{lot_id, running} | acc])
  end

  defp percent_half_up(amount_cents, percent) do
    div(amount_cents * percent * 2 + 100, 200)
  end
end
