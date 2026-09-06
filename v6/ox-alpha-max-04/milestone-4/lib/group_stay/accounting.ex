defmodule GroupStay.Accounting do
  @moduledoc """
  Room-level deposit accounting.

  Cash and hotel credit fund active room deposits in the rooms' original
  order, filling one room's deposit before moving to the next, and every
  funding operation allocates in the order it was processed. The engine
  derives the current allocations for a group by replaying its funding
  history:

    1. the unattributed senior block - funding from before durable operation
       records existed - allocates first: the group's aggregate legacy cash,
       then its legacy hotel-credit lots in original consumption order;
    2. recorded funding - applied cash payments and hotel-credit applications -
       allocates afterward in durable-record commit order, regardless of
       `occurred_on`;
    3. settlements, reductions, and chargebacks then move the allocated
       amounts exactly as their durable operations report: settled rooms give
       up their allocations, reductions remove a payment's held allocations in
       reverse fill order, and a chargeback reclassifies every remaining
       disposition of the payment.

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

  @legacy_seq 0
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
  Replays the group's funding history and returns the allocation state:

    * `rooms` - the group's rooms in original order, each with its deposit
      requirement, current cash allocations (one per funding source, in fill
      order), current credit allocations (per lot), and whether it is still
      active;
    * `payments` - every durably recorded applied cash payment of the group
      with the current disposition of its cash;
    * `lot_segments` - the funding composition of every issued credit lot, in
      the order used for chargeback entitlement.

  Reading the state changes nothing.
  """
  @spec replay(Group.t()) :: map()
  def replay(group) do
    group = Repo.preload(group, rooms: from(r in Room, order_by: [asc: r.position]))
    records = Repo.all(from r in Record, order_by: [asc: r.sequence])
    record_ids = MapSet.new(records, & &1.operation_id)

    state = %{
      group: group,
      rooms: initial_rooms(group),
      payments: %{},
      lot_segments: %{},
      settle_seen?: false
    }

    state =
      state
      |> place_senior_cash(record_ids)
      |> place_senior_credit()
      |> apply_records(records)

    if group.status == "cancelled" and not state.settle_seen? do
      # Cancelled before durable operation records existed: that cancellation
      # settled every allocation the group ever had.
      settle_without_records(state)
    else
      state
    end
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

  defp apply_records(state, records) do
    Enum.reduce(records, state, fn record, state -> apply_record(state, record) end)
  end

  defp apply_record(state, record) do
    result = Jason.decode!(record.result)

    if result["status"] == "applied" and result["group_id"] == state.group.group_id do
      event(state, record, result)
    else
      state
    end
  end

  defp event(
         state,
         %Record{type: "record_cash_payment", operation_id: op_id, sequence: seq},
         result
       ) do
    place_cash(state, op_id, seq, result["amount_cents"] || 0)
  end

  defp event(state, %Record{type: "apply_hotel_credit", operation_id: op_id}, result) do
    amount = result["amount_cents"] || 0
    placements = compute_fill(state, amount)

    state
    |> occupy_credit(placements)
    |> attribute_operation(op_id)
  end

  defp event(state, %Record{type: "cancel_rooms", operation_id: op_id}, result) do
    settle_event(state, op_id, result["cancelled_room_ids"] || [], result)
  end

  defp event(state, %Record{type: "cancel_group", operation_id: op_id}, result) do
    room_ids = for room <- state.rooms, room.active, do: room.room_id
    settle_event(state, op_id, room_ids, result)
  end

  defp event(state, %Record{type: "reduce_cash_payment"}, result) do
    carve_held(state, result["payment_operation_id"], result["amount_cents"] || 0, :reduced)
  end

  defp event(state, %Record{type: "charge_back_payment"}, result) do
    chargeback_event(state, result["payment_operation_id"])
  end

  defp event(state, _record, _result), do: state

  ## The unattributed senior block

  # Legacy cash: held entries whose operation never produced a durable record.
  defp place_senior_cash(state, record_ids) do
    senior_cash =
      Repo.all(
        from e in Entry,
          where: e.group_id == ^state.group.id and e.type == "cash_held",
          select: {e.operation_id, e.amount_cents}
      )
      |> Enum.filter(fn {operation_id, _amount} ->
        not MapSet.member?(record_ids, operation_id)
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    place_cash(state, :legacy, @legacy_seq, senior_cash)
  end

  # Legacy credit: unattributed applications in original consumption order.
  defp place_senior_credit(state) do
    state.group.id
    |> Credit.senior_applications()
    |> Enum.reduce(state, fn portion, state ->
      placements = compute_fill(state, portion.amount)

      state
      |> occupy_credit(placements)
      |> attribute_senior(placements, portion.lot_id)
    end)
  end

  ## Funding placement

  defp place_cash(state, source, seq, amount) when amount > 0 do
    placements = compute_fill(state, amount)

    state =
      Enum.reduce(placements, state, fn {room_id, take}, state ->
        update_room(state, room_id, fn room ->
          %{room | cash: room.cash ++ [%{source: source, amount: take, seq: seq}]}
        end)
      end)

    if is_binary(source) do
      state
      |> bump_payment(source, :recorded, amount)
      |> bump_payment(source, :held, amount)
    else
      state
    end
  end

  defp place_cash(state, _source, _seq, _amount), do: state

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

  defp occupy_credit(state, placements) do
    Enum.reduce(placements, state, fn {room_id, take}, state ->
      update_room(state, room_id, fn room ->
        %{room | credit_occupancy: room.credit_occupancy + take}
      end)
    end)
  end

  defp attribute_senior(state, placements, lot_id) do
    Enum.reduce(placements, state, fn {room_id, take}, state ->
      update_room(state, room_id, fn room ->
        %{room | credit: room.credit ++ [%{lot_id: lot_id, amount: take, kind: :senior}]}
      end)
    end)
  end

  # Current credit attribution for a recorded application comes from its
  # room-scoped application rows.
  defp attribute_operation(state, operation_id) do
    by_db_id = Map.new(state.rooms, &{&1.db_id, &1.room_id})

    state.group.id
    |> Credit.applications_for_operation(operation_id)
    |> Enum.reduce(state, fn application, state ->
      case by_db_id[application.room_id] do
        nil -> state
        room_id -> attribute_row(state, room_id, application)
      end
    end)
  end

  defp attribute_row(state, room_id, application) do
    update_room(state, room_id, fn room ->
      %{
        room
        | credit:
            room.credit ++ [%{lot_id: application.lot_id, amount: application.amount, kind: :row}]
      }
    end)
  end

  ## Settlements, reductions, and chargebacks

  defp settle_event(state, settle_op_id, room_ids, result) do
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

    state =
      if disposition && settled != [] do
        Enum.reduce(settled, state, fn alloc, state ->
          state
          |> bump_payment(alloc.source, disposition, alloc.amount)
          |> bump_payment(alloc.source, :held, -alloc.amount)
        end)
      else
        state
      end

    state =
      if (result["credit_issued_cents"] || 0) > 0 and settled != [] do
        segments = merge_segments(Enum.sort_by(settled, & &1.seq))
        put_in(state, [:lot_segments, settle_op_id], segments)
      else
        state
      end

    state =
      Enum.reduce(room_ids, state, fn room_id, state ->
        update_room(state, room_id, fn room ->
          if room.active do
            %{room | active: false, cash: [], credit: [], credit_occupancy: 0}
          else
            room
          end
        end)
      end)

    %{state | settle_seen?: true}
  end

  defp carve_held(state, payment_operation_id, amount, disposition)
       when is_binary(payment_operation_id) and amount > 0 do
    # The payment's held allocations in fill order; removal walks them in
    # reverse fill order.
    allocs =
      state.rooms
      |> Enum.filter(& &1.active)
      |> Enum.flat_map(fn room -> Enum.map(room.cash, &{room.room_id, &1}) end)
      |> Enum.filter(fn {_room_id, alloc} -> alloc.source == payment_operation_id end)
      |> Enum.reverse()

    {carved, _remaining} =
      Enum.reduce_while(allocs, {[], amount}, fn {room_id, alloc}, {acc, remaining} ->
        if remaining > 0 do
          take = min(alloc.amount, remaining)
          {:cont, {[{room_id, take} | acc], remaining - take}}
        else
          {:halt, {acc, remaining}}
        end
      end)

    carved = Enum.reverse(carved)
    taken = Enum.reduce(carved, 0, fn {_room_id, take}, acc -> acc + take end)

    state =
      Enum.reduce(carved, state, fn {room_id, take}, state ->
        update_room(state, room_id, fn room ->
          %{room | cash: subtract_from_allocation(room.cash, payment_operation_id, take)}
        end)
      end)

    state
    |> bump_payment(payment_operation_id, :held, -taken)
    |> bump_payment(payment_operation_id, disposition, taken)
  end

  defp carve_held(state, _payment_operation_id, _amount, _disposition), do: state

  # A payment holds at most one allocation per room, so removing `take` from a
  # room touches exactly its one allocation.
  defp subtract_from_allocation(cash, source, take) do
    cash
    |> Enum.map(fn
      %{source: ^source} = alloc -> %{alloc | amount: alloc.amount - take}
      alloc -> alloc
    end)
    |> Enum.filter(&(&1.amount > 0))
  end

  defp chargeback_event(state, payment_operation_id) when is_binary(payment_operation_id) do
    payment = Map.get(state.payments, payment_operation_id, empty_payment())
    # The carve moves the held portion to charged-back cash; the refunded,
    # retained, and converted portions are reclassified on top of it.
    state = carve_held(state, payment_operation_id, payment.held, :charged_back)

    state
    |> bump_payment(payment_operation_id, :refunded, -payment.refunded)
    |> bump_payment(payment_operation_id, :retained, -payment.retained)
    |> bump_payment(payment_operation_id, :converted, -payment.converted)
    |> bump_payment(
      payment_operation_id,
      :charged_back,
      payment.refunded + payment.retained + payment.converted
    )
  end

  defp chargeback_event(state, _other), do: state

  defp settle_without_records(state) do
    rooms =
      Enum.map(state.rooms, &%{&1 | active: false, cash: [], credit: [], credit_occupancy: 0})

    %{state | rooms: rooms}
  end

  defp merge_segments([]), do: []

  defp merge_segments([first | rest]) do
    initial = [%{source: first.source, principal: first.amount, seq: first.seq}]

    Enum.reduce(rest, initial, fn alloc, segments ->
      case List.last(segments) do
        last when last.source == alloc.source ->
          List.replace_at(segments, -1, %{last | principal: last.principal + alloc.amount})

        _other ->
          segments ++ [%{source: alloc.source, principal: alloc.amount, seq: alloc.seq}]
      end
    end)
  end

  defp update_room(state, room_id, fun) do
    Map.update!(state, :rooms, fn rooms ->
      Enum.map(rooms, fn room ->
        if room.room_id == room_id, do: fun.(room), else: room
      end)
    end)
  end

  defp bump_payment(state, payment_operation_id, key, delta)
       when is_binary(payment_operation_id) do
    Map.update!(state, :payments, fn payments ->
      payment = Map.get(payments, payment_operation_id, empty_payment())
      Map.put(payments, payment_operation_id, Map.update!(payment, key, &(&1 + delta)))
    end)
  end

  defp bump_payment(state, _legacy_source, _key, _delta), do: state

  defp empty_payment do
    %{recorded: 0, held: 0, refunded: 0, retained: 0, converted: 0, reduced: 0, charged_back: 0}
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
  Places `amount` of new funding into the active rooms in original order,
  respecting each room's remaining deposit capacity.
  """
  def fill_rooms(state, amount), do: compute_fill(state, amount)

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

  @doc "The unattributed senior credit portions funding the named rooms."
  def settled_senior_credit(state, room_ids) do
    ids = MapSet.new(room_ids)

    state.rooms
    |> Enum.filter(&(&1.active and MapSet.member?(ids, &1.room_id)))
    |> Enum.flat_map(& &1.credit)
    |> Enum.filter(&(&1.kind == :senior))
    |> Enum.group_by(& &1.lot_id, & &1.amount)
    |> Enum.map(fn {lot_id, amounts} -> %{lot_id: lot_id, amount: Enum.sum(amounts)} end)
  end

  @doc "The current disposition of one recorded payment's cash."
  def payment_state(state, payment_operation_id) do
    Map.get(state.payments, payment_operation_id, empty_payment())
  end

  @doc "The funding composition of every issued credit lot, keyed by lot source operation."
  def lot_segments(state), do: state.lot_segments

  @doc "The rendered figures for one room of the replayed state."
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

  ## Payment reconciliation

  @doc """
  The current disposition of one durably recorded cash payment:

      %{payment_operation_id, original_group_id, recorded_cents, held_cents,
        refunded_cents, retained_cents, converted_to_credit_cents,
        reduced_cents, charged_back_cents}

  The six disposition fields are always present and always sum to
  `recorded_cents`. Reading a statement never changes state.
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
      group = fetch_group!(result["group_id"])
      payment = payment_state(replay(group), payment_operation_id)

      {:ok,
       %{
         payment_operation_id: payment_operation_id,
         original_group_id: group.group_id,
         recorded_cents: payment.recorded,
         held_cents: payment.held,
         refunded_cents: payment.refunded,
         retained_cents: payment.retained,
         converted_to_credit_cents: payment.converted,
         reduced_cents: payment.reduced,
         charged_back_cents: payment.charged_back
       }}
    else
      {:error, :payment_not_reconcilable}
    end
  end

  defp fetch_group!(group_id) do
    case Repo.one(from g in Group, where: g.group_id == ^group_id) do
      nil -> raise RuntimeError, "payment references missing group #{group_id}"
      group -> group
    end
  end
end
