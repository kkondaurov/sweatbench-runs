defmodule GroupStay.Accounting do
  @moduledoc """
  Room-level deposit accounting.

  Cash and hotel credit fund active room deposits in the rooms' original
  order, filling one room's deposit before moving to the next, and every
  funding operation allocates in the order it was processed. The engine
  derives the current allocations for every group by replaying the whole
  durable operation history as one timeline:

    1. the unattributed senior block - funding from before durable operation
       records existed - allocates first in each group: the group's aggregate
       legacy cash, then its legacy hotel-credit lots in original consumption
       order;
    2. recorded funding - applied cash payments and hotel-credit applications -
       allocates afterward in durable-record commit order, regardless of
       `occurred_on`;
    3. settlements, reductions, chargebacks, and transfers then move the
       allocated amounts exactly as their durable operations report: settled
       rooms give up their allocations, reductions and chargebacks remove a
       payment's held allocations in reverse allocation order across all
       groups, and a transfer redraws held funding between two groups,
       keeping each moved unit's provenance while placing it as a new
       allocation on the destination.

  Allocations are a pure view over that history: deriving them never changes
  any aggregate cash, credit, or liability balance.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Ledger.Entry
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @flexible_deposit_percent 20
  @credit_bonus_percent 10

  ## Rounding and room requirements

  @doc """
  Rounds `amount * percent / 100` to the nearest cent, with an exact
  half-cent rounding upward.
  """
  @spec percent_half_up(integer(), pos_integer()) :: integer()
  def percent_half_up(amount, percent), do: div(2 * amount * percent + 100, 200)

  @doc """
  The deposit a single room requires: a flexible room rounds 20% of its own
  lodging amount; an advance-purchase room requires its full lodging amount.
  """
  @spec room_deposit_due(map(), map()) :: integer()
  def room_deposit_due(group, room) do
    lodging = room_lodging(group, room)

    case group.rate_plan do
      "advance_purchase" -> lodging
      _other -> percent_half_up(lodging, @flexible_deposit_percent)
    end
  end

  defp room_lodging(group, room) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    room.nightly_rate_cents * nights
  end

  ## Replay

  @doc """
  Replays the complete operation history and returns the allocation world:

    * `groups` - one state per group, keyed by partner group id. Each state
      carries the group with its rooms in original order, every room's
      deposit requirement, current cash allocations (one per funding source,
      in fill order), current credit allocations (per lot), and whether the
      room is still active;
    * `payments` - every durably recorded applied cash payment with the
      current disposition of its cash, wherever that cash currently funds
      rooms, and whether any of it has participated in a transfer;
    * `lot_segments` - the funding composition of every issued credit lot, in
      the order used for chargeback entitlement.

  Reading the world changes nothing.
  """
  @spec replay_all() :: map()
  def replay_all do
    groups =
      Group
      |> order_by([g], asc: g.group_id)
      |> Repo.all()
      |> Repo.preload(rooms: from(r in Room, order_by: [asc: r.position]))

    records = Repo.all(from r in Record, order_by: [asc: r.sequence])
    record_ids = MapSet.new(records, & &1.operation_id)

    world = %{
      groups: Map.new(groups, &{&1.group_id, initial_state(&1)}),
      payments: %{},
      lot_segments: %{},
      alloc_seq: 0
    }

    world =
      Enum.reduce(groups, world, fn group, world ->
        world
        |> place_senior_cash(group, record_ids)
        |> place_senior_credit(group)
      end)

    world = apply_records(world, records)

    Enum.reduce(groups, world, fn group, world ->
      state = group_state(world, group.group_id)

      if group.status == "cancelled" and not state.settle_seen? do
        # Cancelled before durable operation records existed: that
        # cancellation settled every allocation the group ever had.
        put_in(world, [:groups, group.group_id], settle_without_records(state))
      else
        world
      end
    end)
  end

  @doc """
  The replayed state of one group, raising when the group has no state.
  """
  @spec group_state(map(), String.t()) :: map()
  def group_state(world, group_id) do
    case Map.fetch(world.groups, group_id) do
      {:ok, state} -> state
      :error -> raise RuntimeError, "allocation replay has no state for group #{group_id}"
    end
  end

  defp initial_state(group) do
    %{
      group: group,
      group_id: group.group_id,
      rooms: initial_rooms(group),
      settle_seen?: false
    }
  end

  defp initial_rooms(group) do
    Enum.map(group.rooms, fn room ->
      %{
        db_id: room.id,
        room_id: room.room_id,
        status: room.status,
        due: room_deposit_due(group, room),
        lodging: room_lodging(group, room),
        active: true,
        cash: [],
        credit: [],
        credit_occupancy: 0
      }
    end)
  end

  defp apply_records(world, records) do
    Enum.reduce(records, world, fn record, world ->
      result = Jason.decode!(record.result)

      if result["status"] == "applied" do
        event(world, record, result)
      else
        world
      end
    end)
  end

  defp event(world, %Record{type: "record_cash_payment", operation_id: op_id}, result) do
    place_cash(world, result["group_id"], op_id, result["amount_cents"] || 0)
  end

  defp event(world, %Record{type: "apply_hotel_credit", operation_id: op_id}, result) do
    group_id = result["group_id"]
    amount = result["amount_cents"] || 0
    placements = compute_fill(group_state(world, group_id), amount)

    world
    |> occupy_credit(group_id, placements)
    |> attribute_operation(group_id, op_id)
  end

  defp event(world, %Record{type: "cancel_rooms", operation_id: op_id}, result) do
    settle_event(world, result["group_id"], op_id, result["cancelled_room_ids"] || [], result)
  end

  defp event(world, %Record{type: "cancel_group", operation_id: op_id}, result) do
    group_id = result["group_id"]
    room_ids = active_room_ids(group_state(world, group_id))
    settle_event(world, group_id, op_id, room_ids, result)
  end

  defp event(world, %Record{type: "reduce_cash_payment"}, result) do
    payment_operation_id = result["payment_operation_id"]
    amount = result["amount_cents"] || 0
    {_carved, world} = carve_payment(world, payment_operation_id, amount)

    world
    |> bump_payment(payment_operation_id, :held, -amount)
    |> bump_payment(payment_operation_id, :reduced, amount)
  end

  defp event(world, %Record{type: "charge_back_payment"}, result) do
    payment_operation_id = result["payment_operation_id"]
    payment = payment_state(world, payment_operation_id)
    {_carved, world} = carve_payment(world, payment_operation_id, payment.held)

    world
    |> bump_payment(payment_operation_id, :held, -payment.held)
    |> bump_payment(payment_operation_id, :refunded, -payment.refunded)
    |> bump_payment(payment_operation_id, :retained, -payment.retained)
    |> bump_payment(payment_operation_id, :converted, -payment.converted)
    |> bump_payment(
      payment_operation_id,
      :charged_back,
      payment.held + payment.refunded + payment.retained + payment.converted
    )
  end

  defp event(world, %Record{type: "transfer_deposit"}, result) do
    amount = result["amount_cents"] || 0

    {units, world} = carve_held_funding(world, result["source_group_id"], amount)
    world = fill_units(world, result["destination_group_id"], units)

    mark_transferred(world, units)
  end

  defp event(world, _record, _result), do: world

  ## The unattributed senior block

  # Legacy cash: held entries whose operation never produced a durable record.
  defp place_senior_cash(world, group, record_ids) do
    senior_cash =
      Repo.all(
        from e in Entry,
          where: e.group_id == ^group.id and e.type == "cash_held",
          select: {e.operation_id, e.amount_cents}
      )
      |> Enum.filter(fn {operation_id, _amount} ->
        not MapSet.member?(record_ids, operation_id)
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    place_cash(world, group.group_id, :legacy, senior_cash)
  end

  # Legacy credit: unattributed applications in original consumption order.
  defp place_senior_credit(world, group) do
    group.id
    |> Credit.senior_applications()
    |> Enum.reduce(world, fn portion, world ->
      placements = compute_fill(group_state(world, group.group_id), portion.amount)

      world
      |> occupy_credit(group.group_id, placements)
      |> attribute_senior(group.group_id, placements, portion.lot_id)
    end)
  end

  ## Funding placement

  defp place_cash(world, group_id, source, amount) when amount > 0 do
    placements = compute_fill(group_state(world, group_id), amount)
    seq = world.alloc_seq

    allocs =
      Enum.with_index(placements, fn {room_id, take}, index ->
        {room_id, %{source: source, amount: take, alloc: seq + index}}
      end)

    world =
      Enum.reduce(allocs, world, fn {room_id, alloc}, world ->
        update_room(world, group_id, room_id, fn room ->
          %{room | cash: room.cash ++ [alloc]}
        end)
      end)

    world = %{world | alloc_seq: seq + length(allocs)}

    if is_binary(source) do
      world
      |> bump_payment(source, :recorded, amount)
      |> bump_payment(source, :held, amount)
    else
      world
    end
  end

  defp place_cash(world, _group_id, _source, _amount), do: world

  # Fills `amount` into the active rooms in original order, up to each room's
  # remaining deposit capacity.
  defp compute_fill(state, amount) do
    {placements, _remaining} =
      Enum.reduce(state.rooms, {[], amount}, fn room, {acc, remaining} ->
        cond do
          remaining <= 0 or not room.active ->
            {acc, remaining}

          true ->
            capacity = max(room.due - room.credit_occupancy - cash_total(room), 0)
            take = min(capacity, remaining)

            if take > 0 do
              {acc ++ [{room.room_id, take}], remaining - take}
            else
              {acc, remaining}
            end
        end
      end)

    placements
  end

  defp occupy_credit(world, group_id, placements) do
    Enum.reduce(placements, world, fn {room_id, take}, world ->
      update_room(world, group_id, room_id, fn room ->
        %{room | credit_occupancy: room.credit_occupancy + take}
      end)
    end)
  end

  defp attribute_senior(world, group_id, placements, lot_id) do
    seq = world.alloc_seq

    {world, count} =
      Enum.reduce(placements, {world, 0}, fn {room_id, take}, {world, index} ->
        world =
          update_room(world, group_id, room_id, fn room ->
            %{
              room
              | credit:
                  room.credit ++
                    [%{lot_id: lot_id, amount: take, kind: :senior, alloc: seq + index}]
            }
          end)

        {world, index + 1}
      end)

    %{world | alloc_seq: seq + count}
  end

  # Current credit attribution for a recorded application comes from its
  # room-scoped application rows, which are written once when the credit is
  # applied and are never moved.
  defp attribute_operation(world, group_id, operation_id) do
    state = group_state(world, group_id)
    by_db_id = Map.new(state.rooms, &{&1.db_id, &1.room_id})
    seq = world.alloc_seq

    {world, count} =
      state.group.id
      |> Credit.applications_for_operation(operation_id)
      |> Enum.reduce({world, 0}, fn application, {world, index} ->
        case by_db_id[application.room_id] do
          nil ->
            {world, index}

          room_id ->
            world =
              update_room(world, group_id, room_id, fn room ->
                %{
                  room
                  | credit:
                      room.credit ++
                        [
                          %{
                            lot_id: application.lot_id,
                            amount: application.amount,
                            kind: :row,
                            alloc: seq + index
                          }
                        ]
                }
              end)

            {world, index + 1}
        end
      end)

    %{world | alloc_seq: seq + count}
  end

  ## Settlements, reductions, chargebacks, and transfers

  defp settle_event(world, group_id, settle_op_id, room_ids, result) do
    state = group_state(world, group_id)
    room_ids = MapSet.new(room_ids)

    settled =
      state.rooms
      |> Enum.filter(&(&1.active and MapSet.member?(room_ids, &1.room_id)))
      |> Enum.flat_map(& &1.cash)

    disposition =
      cond do
        (result["refunded_cents"] || 0) > 0 -> :refunded
        (result["retained_cents"] || 0) > 0 -> :retained
        (result["credit_issued_cents"] || 0) > 0 -> :converted
        true -> nil
      end

    world =
      if disposition && settled != [] do
        Enum.reduce(settled, world, fn alloc, world ->
          world
          |> bump_payment(alloc.source, disposition, alloc.amount)
          |> bump_payment(alloc.source, :held, -alloc.amount)
        end)
      else
        world
      end

    world =
      if (result["credit_issued_cents"] || 0) > 0 and settled != [] do
        segments = merge_segments(Enum.sort_by(settled, & &1.alloc))
        put_in(world, [:lot_segments, settle_op_id], segments)
      else
        world
      end

    state =
      Enum.reduce(room_ids, state, fn room_id, state ->
        update_state_room(state, room_id, fn room ->
          if room.active do
            %{room | active: false, cash: [], credit: [], credit_occupancy: 0}
          else
            room
          end
        end)
      end)

    put_in(world, [:groups, group_id], %{state | settle_seen?: true})
  end

  @doc """
  Removes `amount` of one recorded payment's held cash, wherever it currently
  funds active rooms, in reverse allocation order across all groups. Returns
  the removed total per holding group together with the updated world.
  """
  @spec carve_payment(map(), String.t(), pos_integer()) :: {map(), map()}
  def carve_payment(world, payment_operation_id, amount)
      when is_binary(payment_operation_id) and amount > 0 do
    allocs =
      Enum.flat_map(world.groups, fn {group_id, state} ->
        state.rooms
        |> Enum.filter(& &1.active)
        |> Enum.flat_map(fn room -> Enum.map(room.cash, &{group_id, room.room_id, &1}) end)
        |> Enum.filter(fn {_group_id, _room_id, alloc} ->
          alloc.source == payment_operation_id
        end)
      end)
      |> Enum.sort_by(fn {_group_id, _room_id, alloc} -> -alloc.alloc end)

    {carved, _remaining} =
      Enum.reduce_while(allocs, {[], amount}, fn {group_id, room_id, alloc}, {acc, remaining} ->
        if remaining > 0 do
          take = min(alloc.amount, remaining)
          {:cont, {[{group_id, room_id, alloc.alloc, take} | acc], remaining - take}}
        else
          {:halt, {acc, remaining}}
        end
      end)

    carved = Enum.reverse(carved)

    carved_by_group =
      Enum.reduce(carved, %{}, fn {group_id, _room_id, _alloc_id, take}, acc ->
        Map.update(acc, group_id, take, &(&1 + take))
      end)

    world =
      Enum.reduce(carved, world, fn {group_id, room_id, alloc_id, take}, world ->
        update_room(world, group_id, room_id, fn room ->
          %{room | cash: remove_alloc(room.cash, alloc_id, take)}
        end)
      end)

    {carved_by_group, world}
  end

  def carve_payment(world, _payment_operation_id, _amount), do: {%{}, world}

  @doc """
  Removes `amount` of the group's held funding - cash and hotel credit
  allocated to active rooms - in reverse allocation order (most recently
  created allocation first), regardless of funding kind. Returns the moved
  units in draw order, each keeping its provenance, together with the
  updated world.
  """
  @spec carve_held_funding(map(), String.t(), pos_integer()) :: {[map()], map()}
  def carve_held_funding(world, group_id, amount) when amount > 0 do
    allocs =
      group_state(world, group_id).rooms
      |> Enum.filter(& &1.active)
      |> Enum.flat_map(fn room ->
        Enum.map(room.cash, &{:cash, room.room_id, &1}) ++
          Enum.map(room.credit, &{:credit, room.room_id, &1})
      end)
      |> Enum.sort_by(fn {_kind, _room_id, alloc} -> -alloc.alloc end)

    {carved, _remaining} =
      Enum.reduce_while(allocs, {[], amount}, fn {kind, room_id, alloc}, {acc, remaining} ->
        if remaining > 0 do
          take = min(alloc.amount, remaining)

          unit =
            case kind do
              :cash ->
                %{kind: :cash, amount: take, payment_operation_id: alloc.source}

              :credit ->
                %{
                  kind: :credit,
                  amount: take,
                  lot_id: alloc.lot_id,
                  senior?: alloc.kind == :senior
                }
            end

          {:cont, {[{room_id, alloc.alloc, unit} | acc], remaining - take}}
        else
          {:halt, {acc, remaining}}
        end
      end)

    moved = Enum.reverse(carved)
    units = Enum.map(moved, fn {_room_id, _alloc_id, unit} -> unit end)

    world =
      Enum.reduce(moved, world, fn {room_id, alloc_id, unit}, world ->
        update_room(world, group_id, room_id, fn room ->
          case unit.kind do
            :cash ->
              %{room | cash: remove_alloc(room.cash, alloc_id, unit.amount)}

            :credit ->
              %{
                room
                | credit: remove_alloc(room.credit, alloc_id, unit.amount),
                  credit_occupancy: room.credit_occupancy - unit.amount
              }
          end
        end)
      end)

    {units, world}
  end

  def carve_held_funding(world, _group_id, _amount), do: {[], world}

  @doc """
  Fills the group's active rooms in their original order with the moved units
  in draw order, keeping each unit's provenance. Each placement is a new
  allocation on the destination, created in fill order.
  """
  @spec fill_units(map(), String.t(), [map()]) :: map()
  def fill_units(world, group_id, units) do
    state = group_state(world, group_id)

    {rooms, {_rest, seq}} =
      Enum.map_reduce(state.rooms, {units, world.alloc_seq}, fn room, {queue, seq} ->
        if room.active do
          fill_room(room, queue, seq)
        else
          {room, {queue, seq}}
        end
      end)

    world
    |> put_in([:groups, group_id], %{state | rooms: rooms})
    |> Map.put(:alloc_seq, seq)
  end

  defp fill_room(room, queue, seq) do
    capacity = max(room.due - room.credit_occupancy - cash_total(room), 0)
    {cash, credit, occupancy, rest, seq} = walk_fill(capacity, queue, [], [], 0, seq)

    {%{
       room
       | cash: room.cash ++ cash,
         credit: room.credit ++ credit,
         credit_occupancy: room.credit_occupancy + occupancy
     }, {rest, seq}}
  end

  defp walk_fill(capacity, queue, cash, credit, occupancy, seq)

  defp walk_fill(_capacity, [], cash, credit, occupancy, seq),
    do: {cash, credit, occupancy, [], seq}

  defp walk_fill(capacity, [unit | rest], cash, credit, occupancy, seq) do
    if capacity <= 0 do
      {cash, credit, occupancy, [unit | rest], seq}
    else
      take = min(unit.amount, capacity)

      {cash, credit, occupancy} =
        case unit.kind do
          :cash ->
            {cash ++ [%{source: unit.payment_operation_id, amount: take, alloc: seq}], credit,
             occupancy}

          :credit ->
            {cash,
             credit ++
               [%{lot_id: unit.lot_id, amount: take, kind: credit_kind(unit), alloc: seq}],
             occupancy + take}
        end

      unit = %{unit | amount: unit.amount - take}
      queue = if unit.amount > 0, do: [unit | rest], else: rest
      walk_fill(capacity - take, queue, cash, credit, occupancy, seq + 1)
    end
  end

  defp credit_kind(%{senior?: true}), do: :senior
  defp credit_kind(_unit), do: :row

  defp mark_transferred(world, units) do
    Enum.reduce(units, world, fn unit, world ->
      if unit.kind == :cash and is_binary(unit.payment_operation_id) do
        Map.update!(world, :payments, fn payments ->
          payment = Map.get(payments, unit.payment_operation_id, empty_payment())
          Map.put(payments, unit.payment_operation_id, %{payment | transferred?: true})
        end)
      else
        world
      end
    end)
  end

  defp settle_without_records(state) do
    rooms =
      Enum.map(state.rooms, &%{&1 | active: false, cash: [], credit: [], credit_occupancy: 0})

    %{state | rooms: rooms}
  end

  defp merge_segments([]), do: []

  defp merge_segments([first | rest]) do
    initial = [%{source: first.source, principal: first.amount, seq: first.alloc}]

    Enum.reduce(rest, initial, fn alloc, segments ->
      case List.last(segments) do
        last when last.source == alloc.source ->
          List.replace_at(segments, -1, %{last | principal: last.principal + alloc.amount})

        _other ->
          segments ++ [%{source: alloc.source, principal: alloc.amount, seq: alloc.alloc}]
      end
    end)
  end

  defp update_room(world, group_id, room_id, fun) do
    put_in(
      world,
      [:groups, group_id],
      update_state_room(group_state(world, group_id), room_id, fun)
    )
  end

  defp update_state_room(state, room_id, fun) do
    Map.update!(state, :rooms, fn rooms ->
      Enum.map(rooms, fn room ->
        if room.room_id == room_id, do: fun.(room), else: room
      end)
    end)
  end

  defp bump_payment(world, payment_operation_id, key, delta)
       when is_binary(payment_operation_id) do
    Map.update!(world, :payments, fn payments ->
      payment = Map.get(payments, payment_operation_id, empty_payment())
      Map.put(payments, payment_operation_id, Map.update!(payment, key, &(&1 + delta)))
    end)
  end

  defp bump_payment(world, _legacy_source, _key, _delta), do: world

  defp empty_payment do
    %{
      recorded: 0,
      held: 0,
      refunded: 0,
      retained: 0,
      converted: 0,
      reduced: 0,
      charged_back: 0,
      transferred?: false
    }
  end

  defp remove_alloc(allocs, alloc_id, take) do
    allocs
    |> Enum.map(fn
      %{alloc: ^alloc_id} = alloc -> %{alloc | amount: alloc.amount - take}
      alloc -> alloc
    end)
    |> Enum.filter(&(&1.amount > 0))
  end

  defp cash_total(room), do: Enum.reduce(room.cash, 0, &(&1.amount + &2))

  ## Current-state reads for live operations and views

  @doc "The group's active room identifiers in original room order."
  def active_room_ids(state) do
    for room <- state.rooms, room.active, do: room.room_id
  end

  @doc "The database ids of the named rooms, in original room order."
  def room_db_ids(state, room_ids) do
    ids = MapSet.new(room_ids)
    for room <- state.rooms, MapSet.member?(ids, room.room_id), do: room.db_id
  end

  @doc """
  The total outstanding deposit of the group's active rooms: what their
  deposits still require beyond the cash and credit already funding them.
  """
  def active_outstanding(state) do
    state.rooms
    |> Enum.filter(& &1.active)
    |> Enum.reduce(0, fn room, acc ->
      acc + max(room.due - cash_total(room) - room.credit_occupancy, 0)
    end)
  end

  @doc """
  The cash and hotel credit currently allocated to the group's active rooms.
  """
  def held_funding(world, group_id) do
    world
    |> group_state(group_id)
    |> Map.fetch!(:rooms)
    |> Enum.filter(& &1.active)
    |> Enum.reduce(0, fn room, acc -> acc + cash_total(room) + credit_total(room) end)
  end

  defp credit_total(room), do: Enum.reduce(room.credit, 0, &(&1.amount + &2))

  @doc """
  Assigns ordered credit-lot takes to rooms in original room order, drawing
  the lots in the given order as the funding flows through the rooms. Returns
  one assign per room-and-lot portion, carrying both the partner room
  identifier and the room's database id.
  """
  def place_credit(state, lot_takes) do
    total = Enum.reduce(lot_takes, 0, fn {_lot_id, amount}, acc -> acc + amount end)
    by_room_id = Map.new(state.rooms, &{&1.room_id, &1.db_id})
    interleave(compute_fill(state, total), lot_takes, by_room_id)
  end

  defp interleave(portions, lot_takes, by_room_id) do
    {assigns, _rest} =
      Enum.reduce(portions, {[], lot_takes}, fn {room_id, take}, {acc, takes} ->
        {drawn, takes} = draw_lots(takes, take)

        assigns =
          Enum.map(drawn, fn {lot_id, amount} ->
            %{room_id: room_id, room_db_id: by_room_id[room_id], lot_id: lot_id, amount: amount}
          end)

        {acc ++ assigns, takes}
      end)

    assigns
  end

  defp draw_lots(takes, need) do
    {drawn, rest, _remaining} =
      Enum.reduce_while(takes, {[], [], need}, fn {lot_id, available}, {acc, rest, remaining} ->
        cond do
          remaining <= 0 ->
            {:halt, {acc, rest ++ [{lot_id, available}], 0}}

          available <= remaining ->
            {:cont, {acc ++ [{lot_id, available}], rest, remaining - available}}

          true ->
            {:halt, {acc ++ [{lot_id, remaining}], rest ++ [{lot_id, available - remaining}], 0}}
        end
      end)

    {drawn, rest}
  end

  @doc "The cash allocations of the named rooms, in fill order."
  def settled_room_cash(state, room_ids) do
    ids = MapSet.new(room_ids)

    state.rooms
    |> Enum.filter(&(&1.active and MapSet.member?(ids, &1.room_id)))
    |> Enum.flat_map(& &1.cash)
  end

  @doc """
  The credit allocations of the named rooms, grouped by lot: the amounts that
  settle with those rooms, whatever lot or operation they came from.
  """
  def settled_room_credit(state, room_ids) do
    ids = MapSet.new(room_ids)

    state.rooms
    |> Enum.filter(&(&1.active and MapSet.member?(ids, &1.room_id)))
    |> Enum.flat_map(& &1.credit)
    |> Enum.group_by(& &1.lot_id, & &1.amount)
    |> Enum.map(fn {lot_id, amounts} -> %{lot_id: lot_id, amount: Enum.sum(amounts)} end)
  end

  @doc "The current disposition of one recorded payment's cash."
  def payment_state(world, payment_operation_id) do
    Map.get(world.payments, payment_operation_id, empty_payment())
  end

  @doc "The funding composition of every issued credit lot, keyed by lot source operation."
  def lot_segments(world), do: world.lot_segments

  @doc """
  The rendered figures for one room of the replayed state.
  """
  def room_figures(state_room) do
    %{
      active: state_room.active,
      due: state_room.due,
      cash: cash_total(state_room),
      credit: state_room.credit_occupancy
    }
  end

  @doc """
  A payment's entitlement in one issued credit lot: the 10%-bonus value of the
  settled cash through that payment minus the value through the preceding
  funding source, both rounded half-up, so the entitlements telescope exactly
  to the issued lot.
  """
  def entitlement(segments, payment_operation_id) do
    segments
    |> Enum.sort_by(& &1.seq)
    |> Enum.map_reduce(0, fn segment, cumulative ->
      next = cumulative + segment.principal

      share =
        percent_half_up(next, 100 + @credit_bonus_percent) -
          percent_half_up(cumulative, 100 + @credit_bonus_percent)

      {if(segment.source == payment_operation_id, do: share, else: 0), next}
    end)
    |> elem(0)
    |> Enum.sum()
  end

  @doc """
  The payment's held cash per holding group, ordered by group id. Groups
  holding none of the payment's cash are omitted.
  """
  @spec held_by_group(map(), String.t()) :: [%{group_id: String.t(), amount: pos_integer()}]
  def held_by_group(world, payment_operation_id) do
    Enum.flat_map(world.groups, fn {group_id, state} ->
      total =
        state.rooms
        |> Enum.filter(& &1.active)
        |> Enum.flat_map(& &1.cash)
        |> Enum.filter(&(&1.source == payment_operation_id))
        |> Enum.reduce(0, &(&1.amount + &2))

      if total > 0, do: [%{group_id: group_id, amount: total}], else: []
    end)
    |> Enum.sort_by(& &1.group_id)
  end

  ## Payment reconciliation

  @doc """
  The current disposition of one durably recorded cash payment:

      %{payment_operation_id, original_group_id, recorded_cents, held_cents,
        refunded_cents, retained_cents, converted_to_credit_cents,
        reduced_cents, charged_back_cents}

  The six disposition fields are always present and always sum to
  `recorded_cents`. Once any funding from the payment has participated in a
  transfer, the statement also carries `held_by_group`: the payment's held
  cash per holding group, ordered by group id, summing to `held_cents`.
  Reading a statement never changes state.
  """
  @spec payment_statement(String.t()) ::
          {:ok, map()} | {:error, :operation_not_found | :payment_not_reconcilable}
  def payment_statement(payment_operation_id) do
    case Repo.get_by(Record, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      %Record{type: "record_cash_payment"} = record ->
        statement(record, payment_operation_id)

      %Record{} ->
        {:error, :payment_not_reconcilable}
    end
  end

  defp statement(record, payment_operation_id) do
    result = Jason.decode!(record.result)

    if result["status"] == "applied" do
      world = replay_all()
      group = fetch_group!(result["group_id"])
      payment = payment_state(world, payment_operation_id)

      base = %{
        payment_operation_id: payment_operation_id,
        original_group_id: group.group_id,
        recorded_cents: payment.recorded,
        held_cents: payment.held,
        refunded_cents: payment.refunded,
        retained_cents: payment.retained,
        converted_to_credit_cents: payment.converted,
        reduced_cents: payment.reduced,
        charged_back_cents: payment.charged_back
      }

      {:ok, maybe_hold_by_group(base, payment, world, payment_operation_id)}
    else
      {:error, :payment_not_reconcilable}
    end
  end

  defp maybe_hold_by_group(base, payment, world, payment_operation_id) do
    if payment.transferred? do
      held_by_group =
        Enum.map(held_by_group(world, payment_operation_id), fn holding ->
          %{group_id: holding.group_id, amount_cents: holding.amount}
        end)

      Map.put(base, :held_by_group, held_by_group)
    else
      base
    end
  end

  defp fetch_group!(group_id) do
    case Repo.one(from g in Group, where: g.group_id == ^group_id) do
      nil -> raise RuntimeError, "payment references missing group #{group_id}"
      group -> group
    end
  end
end
