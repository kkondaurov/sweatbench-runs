defmodule GroupStay.Deposits.LegacyBackfill do
  @moduledoc """
  Materializes room allocations for funding that predates this release.

  Funding without a durable operation record cannot be attributed to any
  payment, so each active group's unattributed cash is brought forward as one
  aggregate senior block, followed by its unattributed hotel-credit
  applications in original lot consumption order. Funding represented by
  durable operation records is allocated afterwards in record commit order.
  Only allocations are created; no aggregate balance changes.
  """

  import Ecto.Query

  alias GroupStay.Deposits.CashAllocation
  alias GroupStay.Deposits.CreditApplication
  alias GroupStay.Deposits.Group
  alias GroupStay.Deposits.LedgerEntry
  alias GroupStay.Deposits.Room
  alias GroupStay.Repo
  alias GroupStay.Operations.Record

  @cash_kind "cash"
  @payment_type "record_cash_payment"
  @credit_type "apply_hotel_credit"

  def run do
    funding_by_group = durable_funding_by_group()

    rooms_query = from(r in Room, order_by: r.position)

    Repo.all(from(g in Group, preload: [rooms: ^rooms_query]))
    |> Enum.each(fn group ->
      state = backfill_group(group, Map.get(funding_by_group, group.group_id, []))
      insert_cash_allocations(group.id, state.cash_pieces)
    end)

    :ok
  end

  defp backfill_group(%Group{status: "active"} = group, durable_funding) do
    payments = Enum.filter(durable_funding, &(&1.type == @payment_type))
    credit_ops = Enum.filter(durable_funding, &(&1.type == @credit_type))

    {_cash_matches, legacy_entries} =
      match_by_amount_and_time(group_cash_entries(group.id), payments)

    {credit_matches, legacy_applications} =
      match_by_amount_and_time(group_credit_applications(group.id), credit_ops)

    new_state(group)
    |> place_cash(legacy_total(legacy_entries), nil)
    |> place_legacy_credit_lots(legacy_applications)
    |> place_durable(durable_funding, credit_matches)
  end

  defp backfill_group(%Group{}, _durable_funding) do
    %{capacities: [], cash_pieces: [], seq: 0}
  end

  defp insert_cash_allocations(group_id, pieces) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(pieces, fn piece ->
        %{
          id: Ecto.UUID.generate(),
          group_id: group_id,
          room_id: piece.room_id,
          operation_id: piece.operation_id,
          amount_cents: piece.amount_cents,
          fill_seq: piece.fill_seq,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(CashAllocation, rows)
  end

  defp durable_funding_by_group do
    Repo.all(from(r in Record, order_by: r.seq))
    |> Enum.flat_map(&funding_event/1)
    |> Enum.group_by(& &1.group_id)
  end

  defp funding_event(%Record{type: type} = record) when type in [@payment_type, @credit_type] do
    payload = Jason.decode!(record.payload)

    case Jason.decode!(record.result) do
      %{"status" => "applied"} ->
        [
          %{
            type: type,
            operation_id: record.operation_id,
            group_id: payload["group_id"],
            amount: payload["amount_cents"],
            committed_at: record.inserted_at
          }
        ]

      _other ->
        []
    end
  end

  defp funding_event(_record), do: []

  defp group_cash_entries(group_id) do
    Repo.all(
      from(e in LedgerEntry,
        where: e.group_id == ^group_id and e.kind == ^@cash_kind,
        order_by: [asc: e.inserted_at, asc: e.id]
      )
    )
  end

  defp group_credit_applications(group_id) do
    Repo.all(
      from(a in CreditApplication,
        where: a.group_id == ^group_id,
        order_by: [asc: a.inserted_at, asc: a.id]
      )
    )
  end

  # Greedy attribution in commit order: each durable funding record claims the
  # unconsumed entry or application row with the same amount whose timestamp is
  # closest to the record's own commit time. Whatever stays unclaimed counts as
  # legacy funding from before durable records existed.
  defp match_by_amount_and_time(items, fundings) do
    Enum.reduce(fundings, {%{}, items}, fn funding, {acc, remaining} ->
      case pick_nearest(remaining, funding.amount, funding.committed_at) do
        nil ->
          {acc, remaining}

        item ->
          {Map.put(acc, funding.operation_id, item), List.delete(remaining, item)}
      end
    end)
  end

  defp pick_nearest(items, amount, committed_at) do
    items
    |> Enum.filter(&(&1.amount_cents == amount))
    |> Enum.min_by(&abs(DateTime.diff(&1.inserted_at, committed_at)), fn -> nil end)
  end

  defp legacy_total(applications), do: Enum.sum(Enum.map(applications, & &1.amount_cents))

  defp new_state(group) do
    capacities =
      group.rooms
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&{&1.id, &1.deposit_due_cents || 0})

    %{capacities: capacities, cash_pieces: [], seq: 0}
  end

  defp place_cash(state, amount, operation_id) when amount > 0 do
    {pieces, capacities} = split(state.capacities, amount)

    cash_pieces =
      pieces
      |> Enum.with_index()
      |> Enum.map(fn {{room_id, take}, index} ->
        %{
          room_id: room_id,
          operation_id: operation_id,
          amount_cents: take,
          fill_seq: state.seq + index + 1
        }
      end)

    %{
      state
      | capacities: capacities,
        cash_pieces: state.cash_pieces ++ cash_pieces,
        seq: state.seq + length(cash_pieces)
    }
  end

  defp place_cash(state, _amount, _operation_id), do: state

  defp place_legacy_credit_lots(state, applications) do
    applications
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.sort_by(fn {lot_id, apps} -> {earliest_consumption(apps), lot_id} end)
    |> Enum.reduce(state, fn {_lot_id, apps}, acc ->
      apps
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
      |> Enum.reduce(acc, &place_credit(&2, &1))
    end)
  end

  defp earliest_consumption(applications) do
    applications |> Enum.map(& &1.inserted_at) |> Enum.min()
  end

  defp place_durable(state, funding, credit_matches) do
    Enum.reduce(funding, state, fn event, acc ->
      case event.type do
        @payment_type ->
          place_cash(acc, event.amount, event.operation_id)

        @credit_type ->
          case Map.get(credit_matches, event.operation_id) do
            nil -> acc
            application -> place_credit(acc, application)
          end
      end
    end)
  end

  # The first piece reuses the stored application row; any further pieces are
  # inserted as sibling rows so one row always describes one room placement.
  defp place_credit(state, application) do
    {pieces, capacities} = split(state.capacities, application.amount_cents)

    pieces
    |> Enum.with_index()
    |> Enum.each(fn {{room_id, take}, index} ->
      if index == 0 do
        application
        |> Ecto.Changeset.change(room_id: room_id, fill_seq: state.seq + 1, amount_cents: take)
        |> Repo.update!()
      else
        Repo.insert!(%CreditApplication{
          group_id: application.group_id,
          credit_lot_id: application.credit_lot_id,
          room_id: room_id,
          amount_cents: take,
          fill_seq: state.seq + index + 1
        })
      end
    end)

    %{state | capacities: capacities, seq: state.seq + length(pieces)}
  end

  defp split(capacities, amount) do
    {pieces_rev, caps_rev, _remaining} =
      Enum.reduce(capacities, {[], [], amount}, fn {room_id, capacity},
                                                   {pieces, caps, remaining} ->
        take = capacity |> min(remaining) |> max(0)

        if take <= 0 do
          {pieces, [{room_id, capacity} | caps], remaining}
        else
          {[{room_id, take} | pieces], [{room_id, capacity - take} | caps], remaining - take}
        end
      end)

    {Enum.reverse(pieces_rev), Enum.reverse(caps_rev)}
  end
end
