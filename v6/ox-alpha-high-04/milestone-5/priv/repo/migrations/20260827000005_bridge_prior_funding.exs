defmodule GroupStay.Repo.Migrations.BridgePriorFundingIntoRoomAllocations do
  use Ecto.Migration

  import Ecto.Query

  alias GroupStay.Repo

  # Groups funded before this release carry aggregate totals only. Rebuild
  # their funding as room allocations in the documented bring-forward order:
  # an unattributed senior block per group (its aggregate cash first, then
  # its hotel-credit lots in original consumption order), then funding from
  # durable operation records in commit order. No balance changes.
  def up do
    for group <- active_groups() do
      durable = durable_funding(group.group_id)

      durable_cash = Enum.sum(for entry <- durable, entry.fund == "cash", do: entry.amount)
      durable_credit = Enum.sum(for entry <- durable, entry.fund == "credit", do: entry.amount)

      legacy_cash = max(group.cash_paid_cents - durable_cash, 0)
      legacy_credit = max(group.credit_paid_cents - durable_credit, 0)

      rooms = Enum.map(rooms_for(group.group_id), &Map.put(&1, :due, room_due(group, &1)))

      # Applications this release's predecessors kept per applied lot, in
      # consumption order, split into legacy and durable-recorded halves.
      durable_ids = MapSet.new(Enum.map(durable, & &1.operation_id))
      applications = credit_applications(group.group_id)

      legacy_applications =
        Enum.filter(applications, fn application ->
          not MapSet.member?(durable_ids, application.applied_operation_id)
        end)

      {rooms, rows} =
        fill_plan(
          rooms,
          legacy_cash,
          legacy_credit,
          legacy_applications,
          durable,
          applications
        )

      apply_plan(group.group_id, rooms, rows)
    end

    backfill_cancelled_group_history()
    settle_cancelled_group_rooms()
  end

  # Under this release the group's paid and due totals describe its active
  # rooms only, and each room carries a status. Groups that cancelled before
  # this release have no active rooms: settle their room view accordingly.
  # Their cash dispositions were reconstructed above; the displayed group
  # totals become zero without moving any classified cash.
  defp settle_cancelled_group_rooms do
    execute("""
    UPDATE rooms
    SET status = 'cancelled', cash_paid_cents = 0, credit_paid_cents = 0
    WHERE group_id IN (SELECT group_id FROM groups WHERE status = 'cancelled')
    """)

    execute("""
    UPDATE groups
    SET lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0,
        cash_paid_cents = 0, credit_paid_cents = 0
    WHERE status = 'cancelled'
    """)
  end

  def down do
    # The reconstructed allocations are purely a re-classification of
    # balances; dropping them restores the aggregate-only view.
    execute("DELETE FROM deposit_dispositions")

    execute("UPDATE rooms SET cash_paid_cents = 0, credit_paid_cents = 0")
  end

  ## Active groups

  defp active_groups do
    repo().all(
      from(g in "groups",
        where: g.status == "active",
        select: %{
          group_id: g.group_id,
          guest_id: g.guest_id,
          arrival_on: g.arrival_on,
          departure_on: g.departure_on,
          rate_plan: g.rate_plan,
          cash_paid_cents: g.cash_paid_cents,
          credit_paid_cents: g.credit_paid_cents
        }
      )
    )
    |> Enum.map(&normalize_dates/1)
  end

  defp normalize_dates(%{arrival_on: %Date{}} = group), do: group

  defp normalize_dates(%{arrival_on: arrival, departure_on: departure} = group) do
    %{group | arrival_on: to_date(arrival), departure_on: to_date(departure)}
  end

  defp to_date(value) when is_binary(value), do: Date.from_iso8601!(value)
  defp to_date(%Date{} = date), do: date

  defp rooms_for(group_id) do
    repo().all(
      from(r in "rooms",
        where: r.group_id == ^group_id,
        order_by: [asc: r.position],
        select: %{room_id: r.room_id, nightly_rate_cents: r.nightly_rate_cents}
      )
    )
    |> Enum.map(&Map.merge(&1, %{cash: 0, credit: 0}))
  end

  defp room_due(group, room) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    lodging = room.nightly_rate_cents * nights

    if group.rate_plan == "flexible" do
      div(lodging * 20 + 50, 100)
    else
      lodging
    end
  end

  # Applied durable payments and credit applications for one group, in
  # durable-record commit order.
  defp durable_funding(group_id) do
    repo().all(
      from(r in "operations",
        where: r.type in ["record_cash_payment", "apply_hotel_credit"],
        order_by: [asc: r.id],
        select: %{type: r.type, result_json: r.result_json}
      )
    )
    |> Enum.map(&{&1.type, Jason.decode!(&1.result_json)})
    |> Enum.filter(fn {_type, result} ->
      result["status"] == "applied" and result["group_id"] == group_id
    end)
    |> Enum.map(fn {type, result} ->
      %{
        operation_id: result["operation_id"],
        fund: if(type == "record_cash_payment", do: "cash", else: "credit"),
        amount: result["amount_cents"]
      }
    end)
  end

  defp credit_applications(group_id) do
    repo().all(
      from(a in "credit_applications",
        where: a.group_id == ^group_id,
        order_by: [asc: a.id],
        select: %{
          lot_id: a.lot_id,
          amount_cents: a.amount_cents,
          applied_operation_id: a.applied_operation_id
        }
      )
    )
  end

  # The allocation plan: the unattributed senior block first (aggregate cash,
  # then its hotel-credit lots in original consumption order), then funding
  # from durable operation records in commit order, filling the rooms in
  # original order.
  defp fill_plan(rooms, legacy_cash, legacy_credit, legacy_applications, durable, applications) do
    {rooms, rows} = fill(rooms, "cash", nil, nil, legacy_cash, [])

    # Legacy credit keeps the lot linkage its application rows preserved; any
    # residual beyond those rows stays held without a lot linkage.
    {rooms, rows} =
      Enum.reduce(legacy_applications, {rooms, rows}, fn application, {rooms, rows} ->
        fill(rooms, "credit", nil, application.lot_id, application.amount_cents, rows)
      end)

    matched_legacy = Enum.sum(Enum.map(legacy_applications, & &1.amount_cents))

    {rooms, rows} =
      fill(rooms, "credit", nil, nil, max(legacy_credit - matched_legacy, 0), rows)

    Enum.reduce(durable, {rooms, rows}, fn entry, {rooms, rows} ->
      case entry.fund do
        "cash" ->
          fill(rooms, "cash", entry.operation_id, nil, entry.amount, rows)

        "credit" ->
          # A credit application may have consumed several lots.
          chunks =
            Enum.filter(applications, &(&1.applied_operation_id == entry.operation_id))

          case chunks do
            [] ->
              fill(rooms, "credit", entry.operation_id, nil, entry.amount, rows)

            chunks ->
              Enum.reduce(chunks, {rooms, rows}, fn chunk, {rooms, rows} ->
                fill(rooms, "credit", entry.operation_id, chunk.lot_id, chunk.amount_cents, rows)
              end)
          end
      end
    end)
  end

  # Distributes `amount` of one fund across the rooms' remaining deposit
  # capacity in original room order, producing one held row per touched room.
  defp fill(rooms, fund, owner, lot_id, amount, rows) do
    {tuples, _left} =
      Enum.map_reduce(rooms, amount, fn room, left ->
        take = min(max(room.due - room.cash - room.credit, 0), max(left, 0))

        room =
          case fund do
            "cash" -> Map.update!(room, :cash, &(&1 + take))
            _fund -> Map.update!(room, :credit, &(&1 + take))
          end

        row =
          if take > 0 do
            %{
              room_id: room.room_id,
              payment_operation_id: owner,
              fund: fund,
              kind: "held",
              lot_id: lot_id,
              amount_cents: take
            }
          end

        {{room, row}, left - take}
      end)

    rooms = Enum.map(tuples, &elem(&1, 0))
    new_rows = tuples |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

    {rooms, rows ++ new_rows}
  end

  defp apply_plan(group_id, rooms, rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    full_rows =
      Enum.map(rows, fn row ->
        row
        |> Map.put(:group_id, group_id)
        |> Map.put(:occurred_on, nil)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    if full_rows != [] do
      repo().insert_all("deposit_dispositions", full_rows)

      for room <- rooms do
        repo().update_all(
          from(r in "rooms",
            where: r.group_id == ^group_id and r.room_id == ^room.room_id
          ),
          set: [
            cash_paid_cents: room.cash,
            credit_paid_cents: room.credit,
            deposit_due_cents: room.due
          ]
        )
      end
    end
  end

  ## Cancelled groups

  # Payments of groups that cancelled before this release were settled as a
  # whole; reconstruct their final dispositions so reconciliation and
  # chargebacks keep working. One settle event per group pre-dates partial
  # settlement, so every recorded payment of the group shares its outcome.
  defp backfill_cancelled_group_history do
    for group <- cancelled_groups() do
      outcome = settle_outcome(group.group_id, group.cash_paid_cents)

      if outcome.kind do
        durable = durable_funding(group.group_id)

        durable_cash =
          Enum.sum(for entry <- durable, entry.fund == "cash", do: entry.amount)

        legacy_cash = max(group.cash_paid_cents - durable_cash, 0)

        funding =
          if legacy_cash > 0 do
            [{nil, legacy_cash}] ++ Enum.map(durable, &{&1.operation_id, &1.amount})
          else
            Enum.map(durable, &{&1.operation_id, &1.amount})
          end

        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        rows =
          for {owner, amount} <- funding do
            %{
              group_id: group.group_id,
              room_id: nil,
              payment_operation_id: owner,
              fund: "cash",
              kind: outcome.kind,
              lot_id: outcome.lot_id,
              amount_cents: amount,
              occurred_on: nil,
              inserted_at: now,
              updated_at: now
            }
          end

        if rows != [], do: repo().insert_all("deposit_dispositions", rows)
      end
    end
  end

  defp cancelled_groups do
    repo().all(
      from(g in "groups",
        where: g.status == "cancelled" and g.cash_paid_cents > 0,
        select: %{group_id: g.group_id, guest_id: g.guest_id, cash_paid_cents: g.cash_paid_cents}
      )
    )
  end

  defp settle_outcome(group_id, cash_paid) do
    totals =
      from(e in "ledger_entries",
        where: e.group_id == ^group_id,
        group_by: e.kind,
        select: {e.kind, sum(e.amount_cents)}
      )
      |> repo().all()
      |> Map.new(fn {kind, total} -> {kind, total || 0} end)

    cond do
      Map.get(totals, "refunded", 0) == cash_paid -> %{kind: "refunded", lot_id: nil}
      Map.get(totals, "retained", 0) == cash_paid -> %{kind: "retained", lot_id: nil}
      true -> %{kind: "converted", lot_id: converted_lot_id(group_id)}
    end
  end

  defp converted_lot_id(group_id) do
    repo().one(
      from(l in "credit_lots",
        join: a in "credit_applications",
        on: a.lot_id == l.id,
        where: a.group_id == ^group_id,
        select: max(l.id)
      )
    )
  end
end
