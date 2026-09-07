defmodule GroupStay.RoomAccounting.OrderBackfill do
  @moduledoc """
  Reconstructs the interleaving of pre-transfer cash and credit allocations.

  Credit rows previously retained their lot but not their funding operation. Replay
  only room occupancy from the durable inbox to recover that association; using
  today's credit total as a queue would misidentify funding after room cancellations.
  No domain balances or audit records are changed.

  Legacy funding is the senior cash-then-credit block introduced by room accounting.
  Its initial credit amount is recovered from the recorded outstanding balances and
  surviving credit. Occupancy is monotone in that initial amount, allowing a bounded
  binary search even for large deposits. Fully settled legacy credit need not be
  recovered: the smallest consistent block gives the same surviving allocations.
  """
  import Ecto.Query
  alias GroupStay.{CashAllocation, RoomAccounting}
  alias GroupStay.Credits.Allocation
  alias GroupStay.Operations.Record
  alias GroupStay.Reservations.Group

  def run(repo) do
    records = repo.all(from r in Record, order_by: r.id)
    payments = Map.new(records, &{&1.operation_id, &1.id})
    cash = repo.all(from a in CashAllocation, order_by: a.id)
    credit = repo.all(from a in Allocation, order_by: a.id)

    credit_positions =
      for group <- repo.all(Group), group.status == "active", reduce: [] do
        positions ->
          history =
            Enum.filter(
              records,
              &(&1.result["status"] == "applied" and &1.result["group_id"] == group.group_id)
            )

          allocations = Enum.filter(credit, &(&1.group_id == group.group_id))

          legacy_cash =
            cash
            |> Enum.filter(&(&1.group_id == group.group_id and is_nil(&1.payment_operation_id)))
            |> Enum.map(& &1.amount_cents)
            |> Enum.sum()

          rooms =
            Enum.map(RoomAccounting.rooms(group), fn room ->
              lodging =
                Date.diff(group.departure_on, group.arrival_on) * room["nightly_rate_cents"]

              due =
                if group.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

              {room["room_id"], due}
            end)

          actual = Enum.sum(Enum.map(allocations, & &1.amount_cents))

          initial =
            %{rooms: rooms, funding: [], observations: []} |> fund(:cash, nil, 0, legacy_cash)

          capacity = Enum.sum(Enum.map(rooms, &elem(&1, 1))) - legacy_cash

          legacy_credit =
            search(0, capacity, fn amount ->
              state = replay(initial, history, amount)

              credit_total(state) >= actual and
                Enum.all?(state.observations, fn {paid, expected} -> paid >= expected end)
            end)

          state = replay(initial, history, legacy_credit)

          unless credit_total(state) == actual and
                   Enum.all?(state.observations, fn {paid, expected} -> paid == expected end),
                 do: raise("Cannot reconstruct historical funding for #{group.group_id}")

          positions ++ match_credit(allocations, state.funding)
      end

    entries =
      Enum.map(cash, &{&1, Map.get(payments, &1.payment_operation_id, 0)}) ++ credit_positions

    entries
    |> Enum.sort_by(fn {allocation, position} -> {position, kind(allocation), allocation.id} end)
    |> Enum.each(fn {allocation, _} ->
      repo.insert_all("allocation_order", [
        %{kind: kind(allocation), allocation_id: allocation.id}
      ])
    end)
  end

  defp replay(initial, history, legacy_credit) do
    Enum.reduce(history, fund(initial, :credit, nil, 0, legacy_credit), fn record, state ->
      result = record.result

      case record.type do
        type when type in ~w(record_cash_payment apply_hotel_credit) ->
          kind = if type == "record_cash_payment", do: :cash, else: :credit
          state = fund(state, kind, record.operation_id, record.id, result["amount_cents"])

          if Map.has_key?(result, "outstanding_deposit_cents") do
            due = Enum.sum(Enum.map(state.rooms, &elem(&1, 1)))
            paid = Enum.sum(Enum.map(state.funding, & &1.amount))

            %{
              state
              | observations: [
                  {paid, due - result["outstanding_deposit_cents"]} | state.observations
                ]
            }
          else
            state
          end

        type when type in ~w(cancel_rooms cancel_group) ->
          ids =
            if type == "cancel_group",
              do: Enum.map(state.rooms, &elem(&1, 0)),
              else: result["cancelled_room_ids"]

          %{
            state
            | rooms: Enum.reject(state.rooms, &(elem(&1, 0) in ids)),
              funding: Enum.reject(state.funding, &(&1.room_id in ids))
          }

        "reduce_cash_payment" ->
          remove_cash(state, result["payment_operation_id"], result["amount_cents"])

        "charge_back_payment" ->
          %{
            state
            | funding:
                Enum.reject(
                  state.funding,
                  &(&1.kind == :cash and &1.payment == result["payment_operation_id"])
                )
          }

        _ ->
          state
      end
    end)
  end

  defp fund(state, kind, payment, position, amount) do
    {funding, _remaining} =
      Enum.reduce(state.rooms, {state.funding, amount}, fn {room_id, due}, {funding, remaining} ->
        paid =
          funding |> Enum.filter(&(&1.room_id == room_id)) |> Enum.map(& &1.amount) |> Enum.sum()

        used = min(remaining, max(due - paid, 0))

        entry = %{
          kind: kind,
          payment: payment,
          position: position,
          room_id: room_id,
          amount: used
        }

        {if(used > 0, do: funding ++ [entry], else: funding), remaining - used}
      end)

    %{state | funding: funding}
  end

  defp remove_cash(state, payment, amount) do
    {funding, _} =
      state.funding
      |> Enum.reverse()
      |> Enum.map_reduce(amount, fn entry, remaining ->
        used =
          if entry.kind == :cash and entry.payment == payment,
            do: min(entry.amount, remaining),
            else: 0

        {%{entry | amount: entry.amount - used}, remaining - used}
      end)

    %{state | funding: funding |> Enum.reverse() |> Enum.reject(&(&1.amount == 0))}
  end

  defp match_credit(allocations, funding) do
    queues = funding |> Enum.filter(&(&1.kind == :credit)) |> Enum.group_by(& &1.room_id)

    {positions, _} =
      Enum.map_reduce(allocations, queues, fn allocation, queues ->
        [entry | rest] = Map.fetch!(queues, allocation.room_id)

        if allocation.amount_cents > entry.amount,
          do: raise("Historical credit allocation crosses funding operations")

        remaining = entry.amount - allocation.amount_cents
        queue = if remaining == 0, do: rest, else: [%{entry | amount: remaining} | rest]
        {{allocation, entry.position}, Map.put(queues, allocation.room_id, queue)}
      end)

    positions
  end

  defp credit_total(state),
    do: state.funding |> Enum.filter(&(&1.kind == :credit)) |> Enum.map(& &1.amount) |> Enum.sum()

  defp search(low, high, _predicate) when low >= high, do: low

  defp search(low, high, predicate) do
    middle = div(low + high, 2)

    if predicate.(middle),
      do: search(low, middle, predicate),
      else: search(middle + 1, high, predicate)
  end

  defp kind(%CashAllocation{}), do: "cash"
  defp kind(%Allocation{}), do: "credit"
end
