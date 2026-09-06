defmodule GroupStay.CashDispositionBackfill do
  import Ecto.Query

  alias GroupStay.{CashDisposition, Funding, Group, OperationRecord, Repo, Room}

  @fields [
    :refunded_cents,
    :retained_cents,
    :converted_cents,
    :reduced_cents,
    :charged_back_cents
  ]

  def backfill(funding_id \\ nil) do
    groups = Repo.all(Group)
    rooms = Repo.all(from r in Room, order_by: [r.group_ref, r.position])
    fundings = Repo.all(from f in Funding, order_by: [f.group_ref, f.funding_order, f.id])

    state =
      %{
        groups: Map.new(groups, &{&1.group_id, &1}),
        rooms: Map.new(rooms, &{&1.id, &1}),
        active_rooms: MapSet.new(Enum.map(rooms, & &1.id)),
        allocations: [],
        next_order: 1,
        dispositions: %{}
      }
      |> allocate_legacy_fundings(fundings)
      |> replay(fundings)

    fundings
    |> Enum.filter(&(is_nil(funding_id) or &1.id == funding_id))
    |> Enum.filter(&(&1.kind == "cash"))
    |> Enum.each(&persist(&1, state))
  end

  defp allocate_legacy_fundings(state, fundings) do
    fundings
    |> Enum.filter(&is_nil(&1.operation_id))
    |> Enum.reduce(state, &allocate_funding(&2, &1))
  end

  defp replay(state, fundings) do
    by_operation = Enum.group_by(fundings, & &1.operation_id)

    Repo.all(from r in OperationRecord, order_by: r.id)
    |> Enum.reduce(state, fn record, state ->
      if record.result["status"] == "applied" do
        replay_record(state, record, Map.get(by_operation, record.operation_id, []))
      else
        state
      end
    end)
  end

  defp replay_record(state, %{operation_type: type}, fundings)
       when type in ["record_cash_payment", "apply_hotel_credit"] do
    Enum.reduce(fundings, state, &allocate_funding(&2, &1))
  end

  defp replay_record(state, %{operation_type: "transfer_deposit"} = record, _fundings) do
    source = record.submission["source_group_id"]
    destination = record.submission["destination_group_id"]
    amount = record.result["amount_cents"]
    {state, chunks} = draw(state, amount, &in_group?(&1, source, state))
    allocate_chunks(state, destination, chunks)
  end

  defp replay_record(state, %{operation_type: type} = record, _fundings)
       when type in ["cancel_group", "cancel_rooms"] do
    group_id = record.result["group_id"]

    room_ids =
      case record.result["cancelled_room_ids"] do
        nil -> active_group_room_ids(state, group_id)
        ids -> room_db_ids(state, group_id, ids)
      end

    field =
      cond do
        record.result["refunded_cents"] > 0 -> :refunded_cents
        record.result["retained_cents"] > 0 -> :retained_cents
        record.submission["refund_method"] == "hotel_credit" -> :converted_cents
        true -> :refunded_cents
      end

    property_id = state.groups[group_id].property_id

    {settled, held} = Enum.split_with(state.allocations, &(&1.room_id in room_ids))

    state
    |> Map.put(:allocations, held)
    |> Map.update!(
      :active_rooms,
      &Enum.reduce(room_ids, &1, fn id, set -> MapSet.delete(set, id) end)
    )
    |> classify(settled, property_id, field)
  end

  defp replay_record(state, %{operation_type: "reduce_cash_payment"} = record, _fundings) do
    payment_id = record.submission["payment_operation_id"]
    funding_ids = funding_ids_for_operation(payment_id)
    {state, removed} = draw(state, record.result["amount_cents"], &(&1.funding_id in funding_ids))

    Enum.reduce(removed, state, fn allocation, state ->
      property_id = property_for_room(state, allocation.room_id)

      add_disposition(
        state,
        allocation.funding_id,
        property_id,
        :reduced_cents,
        allocation.amount
      )
    end)
  end

  defp replay_record(state, %{operation_type: "charge_back_payment"} = record, _fundings) do
    payment_id = record.submission["payment_operation_id"]

    Enum.reduce(funding_ids_for_operation(payment_id), state, fn funding_id, state ->
      {state, removed} = draw(state, :all, &(&1.funding_id == funding_id))

      state =
        Enum.reduce(removed, state, fn allocation, state ->
          add_disposition(
            state,
            funding_id,
            property_for_room(state, allocation.room_id),
            :charged_back_cents,
            allocation.amount
          )
        end)

      reclassify_settled_as_charged_back(state, funding_id)
    end)
  end

  defp replay_record(state, _record, _fundings), do: state

  defp funding_ids_for_operation(operation_id) do
    Repo.all(
      from f in Funding,
        where: f.operation_id == ^operation_id,
        order_by: [f.funding_order, f.id],
        select: f.id
    )
  end

  defp allocate_funding(state, funding) do
    group_id = Repo.get!(Group, funding.group_ref).group_id

    allocate_chunks(state, group_id, [
      %{funding_id: funding.id, amount: funding.original_amount_cents}
    ])
  end

  defp allocate_chunks(state, group_id, chunks) do
    Enum.reduce(active_group_room_ids(state, group_id), {state, chunks}, fn room_id,
                                                                            {state, chunks} ->
      capacity = state.rooms[room_id].deposit_due_cents - allocated_to_room(state, room_id)
      fill_room(state, room_id, capacity, chunks)
    end)
    |> elem(0)
  end

  defp fill_room(state, _room_id, _capacity, []), do: {state, []}
  defp fill_room(state, _room_id, 0, chunks), do: {state, chunks}

  defp fill_room(state, room_id, capacity, [%{amount: amount} = chunk | rest]) do
    used = min(capacity, amount)

    allocation = %{
      funding_id: chunk.funding_id,
      room_id: room_id,
      amount: used,
      order: state.next_order
    }

    state = %{
      state
      | allocations: [allocation | state.allocations],
        next_order: state.next_order + 1
    }

    chunks = if used == amount, do: rest, else: [%{chunk | amount: amount - used} | rest]
    fill_room(state, room_id, capacity - used, chunks)
  end

  defp draw(state, amount, predicate) do
    candidates = state.allocations |> Enum.filter(predicate) |> Enum.sort_by(& &1.order, :desc)
    left = if amount == :all, do: Enum.sum_by(candidates, & &1.amount), else: amount

    {left, removed, replacements} =
      Enum.reduce_while(candidates, {left, [], []}, fn allocation,
                                                       {left, removed, replacements} ->
        used = min(left, allocation.amount)
        removed = [%{allocation | amount: used} | removed]

        replacements =
          if used < allocation.amount,
            do: [%{allocation | amount: allocation.amount - used} | replacements],
            else: replacements

        if used == left,
          do: {:halt, {0, removed, replacements}},
          else: {:cont, {left - used, removed, replacements}}
      end)

    if left != 0, do: raise("cash disposition replay could not draw complete allocation")

    candidate_orders = MapSet.new(removed, & &1.order)
    kept = Enum.reject(state.allocations, &MapSet.member?(candidate_orders, &1.order))
    {%{state | allocations: replacements ++ kept}, Enum.reverse(removed)}
  end

  defp classify(state, allocations, property_id, field) do
    Enum.reduce(allocations, state, fn allocation, state ->
      case Repo.get!(Funding, allocation.funding_id).kind do
        "cash" ->
          add_disposition(state, allocation.funding_id, property_id, field, allocation.amount)

        _ ->
          state
      end
    end)
  end

  defp reclassify_settled_as_charged_back(state, funding_id) do
    Enum.reduce([:refunded_cents, :retained_cents, :converted_cents], state, fn field, state ->
      state.dispositions
      |> Enum.filter(fn {{id, _property_id, candidate}, _amount} ->
        id == funding_id and candidate == field
      end)
      |> Enum.reduce(state, fn {{^funding_id, property_id, ^field} = key, amount}, state ->
        state
        |> put_in([:dispositions, key], 0)
        |> add_disposition(funding_id, property_id, :charged_back_cents, amount)
      end)
    end)
  end

  defp add_disposition(state, _funding_id, _property_id, _field, 0), do: state

  defp add_disposition(state, funding_id, property_id, field, amount) do
    update_in(state, [:dispositions], fn dispositions ->
      Map.update(dispositions, {funding_id, property_id, field}, amount, &(&1 + amount))
    end)
  end

  defp persist(funding, state) do
    group = Repo.get!(Group, funding.group_ref)
    existing = Repo.all(from d in CashDisposition, where: d.funding_id == ^funding.id)

    Enum.each(@fields, fn field ->
      expected = Map.fetch!(funding, field)

      replayed =
        state.dispositions
        |> Enum.filter(fn {{funding_id, _property_id, candidate}, _} ->
          funding_id == funding.id and candidate == field
        end)
        |> Map.new(fn {{_funding_id, property_id, _field}, amount} -> {property_id, amount} end)

      replayed_total = Enum.sum(Map.values(replayed))

      if replayed_total > expected do
        raise "cash disposition replay exceeds funding #{funding.id} #{field}: #{replayed_total} > #{expected}"
      end

      existing_total = Enum.sum_by(existing, &Map.fetch!(&1, field))
      needed = expected - existing_total

      if needed < 0 do
        raise "cash dispositions exceed funding #{funding.id} #{field}"
      end

      needed =
        replayed
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce(needed, fn {property_id, amount}, needed ->
          already =
            existing
            |> Enum.find(&(&1.property_id == property_id))
            |> case do
              nil -> 0
              disposition -> Map.fetch!(disposition, field)
            end

          add = min(max(amount - already, 0), needed)
          write(funding.id, property_id, field, add)
          needed - add
        end)

      write(funding.id, group.property_id, field, needed)
    end)
  end

  defp write(_funding_id, _property_id, _field, 0), do: :ok

  defp write(funding_id, property_id, field, amount) do
    disposition =
      Repo.get_by(CashDisposition, funding_id: funding_id, property_id: property_id) ||
        %CashDisposition{funding_id: funding_id, property_id: property_id}

    disposition
    |> CashDisposition.changeset(%{field => Map.fetch!(disposition, field) + amount})
    |> Repo.insert_or_update!()
  end

  defp active_group_room_ids(state, group_id) do
    group_ref = state.groups[group_id].id

    state.rooms
    |> Map.values()
    |> Enum.filter(&(&1.group_ref == group_ref and MapSet.member?(state.active_rooms, &1.id)))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(& &1.id)
  end

  defp room_db_ids(state, group_id, room_ids) do
    wanted = MapSet.new(room_ids)

    active_group_room_ids(state, group_id)
    |> Enum.filter(&MapSet.member?(wanted, state.rooms[&1].room_id))
  end

  defp in_group?(allocation, group_id, state) do
    state.rooms[allocation.room_id].group_ref == state.groups[group_id].id
  end

  defp property_for_room(state, room_id) do
    group_ref = state.rooms[room_id].group_ref
    state.groups |> Map.values() |> Enum.find(&(&1.id == group_ref)) |> Map.fetch!(:property_id)
  end

  defp allocated_to_room(state, room_id) do
    state.allocations
    |> Enum.filter(&(&1.room_id == room_id))
    |> Enum.sum_by(& &1.amount)
  end
end
