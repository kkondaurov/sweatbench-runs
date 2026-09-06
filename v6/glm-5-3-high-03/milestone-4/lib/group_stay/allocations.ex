defmodule GroupStay.Allocations do
  @moduledoc """
  Room-level deposit accounting: which funding source fills which room, and
  what has become of each source's money since.

  Cash and credit fund active room deposits in the rooms' original order,
  filling one room's deposit before moving to the next; new funding
  operations allocate in operation-processing order. Every allocation row
  records its source — a durable operation identifier, or `nil` for funding
  carried over from before durable operation records existed — and its
  current disposition.

  Groups created by earlier releases have no allocation rows. Their funding
  is brought forward lazily: the funding not represented by durable records
  becomes one unattributed senior block per group (its aggregate cash first,
  then its hotel-credit lots in original consumption order), allocated before
  the funding represented by durable operation records in commit order.
  Creating room allocations never changes an aggregate cash, credit, or
  liability balance.
  """

  import Ecto.Query

  alias GroupStay.Allocations.RoomAllocation
  alias GroupStay.Credits
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  @funding_types ~w(record_cash_payment apply_hotel_credit)

  ## Allocating funding to rooms

  @doc """
  Allocates funding sources across the group's rooms, in the rooms' original
  order, filling one room's deposit before moving to the next. Each source is
  a map with `kind` (`cash` or `credit`), `source_operation_id`, an optional
  `credit_lot_id`, and `amount_cents`.
  """
  def allocate(%Group{} = group, rooms, sources) do
    held = held_totals_by_room(group.id)
    {fills, _remaining} = plan_fills(rooms, held, sources)
    start = next_position(group.id)

    fills
    |> Enum.with_index()
    |> Enum.each(fn {{source, room, amount_cents}, index} ->
      %RoomAllocation{}
      |> Ecto.Changeset.change(%{
        group_id: group.id,
        room_id: room.id,
        kind: source.kind,
        source_operation_id: source.source_operation_id,
        credit_lot_id: source.credit_lot_id,
        amount_cents: amount_cents,
        state: "held",
        position: start + index
      })
      |> Repo.insert!()
    end)
  end

  # Fills the sources across the rooms, in room order within each source.
  # Returns the fills as {source, room, amount_cents} in fill order.
  defp plan_fills(rooms, held, sources) do
    remaining =
      Map.new(rooms, fn room ->
        paid = Map.get(held, room.id, %{cash: 0, credit: 0})
        {room.id, room.deposit_due_cents - paid.cash - paid.credit}
      end)

    do_fill(sources, rooms, remaining, [])
  end

  defp do_fill([], _rooms, remaining, fills), do: {Enum.reverse(fills), remaining}

  defp do_fill([source | rest], rooms, remaining, fills) do
    {fills, remaining} = fill_source(source, rooms, remaining, fills, source.amount_cents)
    do_fill(rest, rooms, remaining, fills)
  end

  defp fill_source(_source, _rooms, remaining, fills, 0), do: {fills, remaining}

  defp fill_source(source, [room | rest_rooms], remaining, fills, left) do
    room_left = Map.fetch!(remaining, room.id)
    taken = min(room_left, left)

    fills = if taken > 0, do: [{source, room, taken} | fills], else: fills
    remaining = Map.put(remaining, room.id, room_left - taken)

    fill_source(source, rest_rooms, remaining, fills, left - taken)
  end

  defp fill_source(_source, [], _remaining, _fills, left) when left > 0 do
    raise "funding exceeds the group's remaining deposit by #{left} cents"
  end

  defp next_position(group_id) do
    Repo.one(
      from a in RoomAllocation,
        where: a.group_id == ^group_id,
        select: max(a.position)
    )
    |> Kernel.||(-1)
    |> Kernel.+(1)
  end

  ## Reading room funding

  @doc """
  The cash and credit currently held on each of the group's rooms, keyed by
  room id. Groups carried over from an earlier release are computed from
  their virtually materialized funding, without writing anything.
  """
  def room_funding(%Group{allocations_initialized: true} = group) do
    held_totals_by_room(group.id)
  end

  def room_funding(%Group{status: "cancelled"}), do: %{}

  def room_funding(%Group{} = group) do
    rooms = active_rooms(group)
    {fills, _remaining} = plan_fills(rooms, %{}, materialization_plan(group))

    Enum.reduce(fills, %{}, fn {source, room, amount_cents}, acc ->
      funding = Map.get(acc, room.id, %{cash: 0, credit: 0})
      kind = String.to_existing_atom(source.kind)
      Map.put(acc, room.id, Map.update!(funding, kind, &(&1 + amount_cents)))
    end)
  end

  defp held_totals_by_room(group_id) do
    Repo.all(
      from a in RoomAllocation,
        where: a.group_id == ^group_id and a.state == "held",
        group_by: [a.room_id, a.kind],
        select: {a.room_id, a.kind, sum(a.amount_cents)}
    )
    |> Enum.reduce(%{}, fn {room_id, kind, total}, acc ->
      funding = Map.get(acc, room_id, %{cash: 0, credit: 0})
      key = String.to_existing_atom(kind)
      Map.put(acc, room_id, Map.update!(funding, key, &(&1 + total)))
    end)
  end

  @doc """
  The group's active rooms, in their original order.
  """
  def active_rooms(%Group{} = group) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group.id and r.status == "active",
        order_by: r.position
    )
  end

  @doc """
  Held allocation rows for the given rooms, in fill order.
  """
  def held_rows_for_rooms(%Group{} = group, rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from a in RoomAllocation,
        where: a.group_id == ^group.id and a.state == "held" and a.room_id in ^room_ids,
        order_by: a.position
    )
  end

  @doc """
  All cash allocation rows of one payment, whatever their disposition.
  """
  def cash_rows_for_payment(group_id, operation_id) do
    Repo.all(
      from a in RoomAllocation,
        where:
          a.group_id == ^group_id and a.source_operation_id == ^operation_id and
            a.kind == "cash",
        order_by: a.position
    )
  end

  @doc """
  The cash of one payment still held on active rooms. For a group carried
  over from an earlier release, the funding of an active group is still
  entirely held; a cancelled group holds none.
  """
  def held_cash_for_payment(
        %Group{allocations_initialized: true} = group,
        operation_id,
        _recorded_cents
      ) do
    Repo.one(
      from a in RoomAllocation,
        where:
          a.group_id == ^group.id and a.source_operation_id == ^operation_id and
            a.kind == "cash" and a.state == "held",
        select: sum(a.amount_cents)
    )
    |> Kernel.||(0)
  end

  def held_cash_for_payment(%Group{status: "active"}, _operation_id, recorded_cents),
    do: recorded_cents

  def held_cash_for_payment(_group, _operation_id, _recorded_cents), do: 0

  @doc """
  The current disposition of one payment's cash: held, refunded, retained,
  converted, reduced, and charged-back cents. The six amounts sum to the
  payment's recorded amount.
  """
  def payment_disposition(
        %Group{allocations_initialized: true} = group,
        operation_id,
        _recorded_cents
      ) do
    cash_rows_for_payment(group.id, operation_id)
    |> Enum.reduce(zero_disposition(), fn row, disposition ->
      key = String.to_existing_atom(row.state)
      Map.update(disposition, key, row.amount_cents, &(&1 + row.amount_cents))
    end)
  end

  def payment_disposition(%Group{status: "active"}, _operation_id, recorded_cents) do
    %{zero_disposition() | held: recorded_cents}
  end

  def payment_disposition(%Group{} = group, _operation_id, recorded_cents) do
    # A group cancelled before this release settled all of its cash at its
    # cancellation, uniformly into one disposition.
    key = String.to_existing_atom(settlement_bucket(group))
    Map.put(zero_disposition(), key, recorded_cents)
  end

  defp zero_disposition do
    %{held: 0, refunded: 0, retained: 0, converted: 0, reduced: 0, charged_back: 0}
  end

  ## Materializing funding carried over from an earlier release

  @doc """
  Persists the room allocations of a group carried over from an earlier
  release, if that has not happened yet. Aggregate balances are not changed;
  only allocation rows are created and the group is marked initialized.
  """
  def materialize_if_needed(%Group{allocations_initialized: true}), do: :ok

  def materialize_if_needed(%Group{status: "cancelled"} = group) do
    # The funding of a group cancelled before this release was settled at its
    # cancellation; reconstruct each recorded payment's disposition so later
    # chargebacks can address it.
    case Repo.one(
           from r in Room,
             where: r.group_id == ^group.id,
             order_by: r.position,
             limit: 1
         ) do
      nil ->
        :ok

      room ->
        bucket = settlement_bucket(group)

        group
        |> durable_funding_records()
        |> Enum.filter(&(&1.type == "record_cash_payment"))
        |> Enum.with_index()
        |> Enum.each(fn {record, index} ->
          %RoomAllocation{}
          |> Ecto.Changeset.change(%{
            group_id: group.id,
            room_id: room.id,
            kind: "cash",
            source_operation_id: record.operation_id,
            amount_cents: record.payload["amount_cents"],
            state: bucket,
            position: index
          })
          |> Repo.insert!()
        end)
    end

    mark_initialized(group)
  end

  def materialize_if_needed(%Group{} = group) do
    rooms = active_rooms(group)
    plan = materialization_plan(group)

    cash = plan |> Enum.filter(&(&1.kind == "cash")) |> Enum.map(& &1.amount_cents) |> Enum.sum()

    credit =
      plan |> Enum.filter(&(&1.kind == "credit")) |> Enum.map(& &1.amount_cents) |> Enum.sum()

    held_cash = group.deposit_paid_cents - group.credit_paid_cents

    unless cash == held_cash and credit == group.credit_paid_cents do
      raise "cannot materialize room allocations for group #{group.group_id}: " <>
              "plan holds #{cash} cash and #{credit} credit cents, " <>
              "the group holds #{held_cash} and #{group.credit_paid_cents}"
    end

    allocate(group, rooms, plan)
    mark_initialized(group)
  end

  defp mark_initialized(%Group{} = group) do
    group
    |> Ecto.Changeset.change(%{allocations_initialized: true})
    |> Repo.update!()
  end

  defp settlement_bucket(%Group{refunded_cents: refunded}) when refunded > 0, do: "refunded"
  defp settlement_bucket(%Group{retained_cents: retained}) when retained > 0, do: "retained"

  defp settlement_bucket(%Group{converted_to_credit_cents: converted}) when converted > 0,
    do: "converted"

  defp settlement_bucket(_group), do: "refunded"

  @doc """
  The funding sources of a group carried over from an earlier release, in
  fill order: the unattributed senior block first (its aggregate cash, then
  its hotel-credit lots in original consumption order), then the funding
  represented by durable operation records in commit order.
  """
  def materialization_plan(%Group{} = group) do
    durable = durable_funding_records(group)
    cash_records = Enum.filter(durable, &(&1.type == "record_cash_payment"))
    credit_records = Enum.filter(durable, &(&1.type == "apply_hotel_credit"))

    held_cash = group.deposit_paid_cents - group.credit_paid_cents
    durable_cash = Enum.sum(Enum.map(cash_records, & &1.payload["amount_cents"]))
    legacy_cash = held_cash - durable_cash

    if legacy_cash < 0 do
      raise "cannot materialize room allocations for group #{group.group_id}: " <>
              "recorded funding exceeds the group's held cash"
    end

    applications = Credits.applications_in_consumption_order(group)
    {legacy_lot_amounts, durable_credit} = peel_applications(applications, credit_records)

    legacy_cash_sources =
      if legacy_cash > 0 do
        [%{kind: "cash", source_operation_id: nil, credit_lot_id: nil, amount_cents: legacy_cash}]
      else
        []
      end

    legacy_credit_sources =
      Enum.map(legacy_lot_amounts, fn {lot_id, amount_cents} ->
        %{
          kind: "credit",
          source_operation_id: nil,
          credit_lot_id: lot_id,
          amount_cents: amount_cents
        }
      end)

    durable_sources =
      Enum.flat_map(durable, fn record ->
        case record.type do
          "record_cash_payment" ->
            [
              %{
                kind: "cash",
                source_operation_id: record.operation_id,
                credit_lot_id: nil,
                amount_cents: record.payload["amount_cents"]
              }
            ]

          "apply_hotel_credit" ->
            durable_credit
            |> Map.get(record.operation_id, [])
            |> Enum.reverse()
            |> Enum.map(fn {lot_id, amount_cents} ->
              %{
                kind: "credit",
                source_operation_id: record.operation_id,
                credit_lot_id: lot_id,
                amount_cents: amount_cents
              }
            end)
        end
      end)

    legacy_cash_sources ++ legacy_credit_sources ++ durable_sources
  end

  defp durable_funding_records(%Group{} = group) do
    Repo.all(from r in OperationRecord, where: r.type in ^@funding_types, order_by: r.id)
    |> Enum.filter(fn record ->
      record.payload["group_id"] == group.group_id and record.result["status"] == "applied"
    end)
  end

  # Attributes the group's credit applications, in consumption order, to the
  # durable apply_hotel_credit records in commit order; whatever cannot be
  # attributed to a record is funding from before durable records existed.
  defp peel_applications(applications, credit_records) do
    queue = Enum.map(credit_records, &{&1.operation_id, &1.payload["amount_cents"]})

    {legacy_reversed, _queue, durable} =
      Enum.reduce(applications, {[], queue, %{}}, fn application, acc ->
        consume_application(application, acc, application.amount_cents)
      end)

    legacy_lot_amounts =
      legacy_reversed
      |> Enum.reverse()
      |> Enum.reduce({[], %{}}, fn {lot_id, amount_cents}, {ordered, sums} ->
        {
          if(lot_id in ordered, do: ordered, else: ordered ++ [lot_id]),
          Map.update(sums, lot_id, amount_cents, &(&1 + amount_cents))
        }
      end)
      |> then(fn {ordered, sums} -> Enum.map(ordered, &{&1, Map.fetch!(sums, &1)}) end)

    {legacy_lot_amounts, durable}
  end

  defp consume_application(_application, acc, 0), do: acc

  defp consume_application(application, {legacy, [], durable}, remaining) do
    {[{application.credit_lot_id, remaining} | legacy], [], durable}
  end

  defp consume_application(
         application,
         {legacy, [{operation_id, available} | rest], durable},
         remaining
       ) do
    taken = min(available, remaining)

    durable =
      Map.update(durable, operation_id, [{application.credit_lot_id, taken}], fn entries ->
        [{application.credit_lot_id, taken} | entries]
      end)

    queue =
      if available - taken == 0,
        do: rest,
        else: [{operation_id, available - taken} | rest]

    acc = {legacy, queue, durable}

    if remaining - taken == 0 do
      acc
    else
      consume_application(application, acc, remaining - taken)
    end
  end

  ## Settling and moving allocations

  @doc """
  Marks allocation rows with a new disposition, optionally attributing them
  to a credit lot created by their conversion.
  """
  def set_state(rows, state, credit_lot_id \\ nil) do
    Enum.each(rows, fn row ->
      row
      |> Ecto.Changeset.change(%{state: state, credit_lot_id: credit_lot_id || row.credit_lot_id})
      |> Repo.update!()
    end)
  end

  @doc """
  Removes held cash of one payment in reverse fill order, marking the removed
  portions as reduced. The rooms' outstanding deposit reopens accordingly.
  """
  def reduce_held(group_id, operation_id, amount_cents) do
    rows =
      Repo.all(
        from a in RoomAllocation,
          where:
            a.group_id == ^group_id and a.source_operation_id == ^operation_id and
              a.kind == "cash" and a.state == "held",
          order_by: [desc: a.position, desc: a.id]
      )

    Enum.reduce_while(rows, amount_cents, fn row, left ->
      taken = min(row.amount_cents, left)

      cond do
        taken == row.amount_cents ->
          row |> Ecto.Changeset.change(%{state: "reduced"}) |> Repo.update!()

        taken > 0 ->
          row
          |> Ecto.Changeset.change(%{amount_cents: row.amount_cents - taken})
          |> Repo.update!()

          %RoomAllocation{}
          |> Ecto.Changeset.change(%{
            group_id: row.group_id,
            room_id: row.room_id,
            kind: row.kind,
            source_operation_id: row.source_operation_id,
            credit_lot_id: row.credit_lot_id,
            amount_cents: taken,
            state: "reduced",
            position: row.position
          })
          |> Repo.insert!()

        true ->
          :ok
      end

      if left - taken == 0, do: {:halt, 0}, else: {:cont, left - taken}
    end)
  end

  @doc """
  The cash contributions that were converted into one credit lot, in the
  funding order used by room accounting, with the unattributed senior block
  first. Contributions already charged back are included, so a lot's
  entitlements keep telescoping to its issued value.
  """
  def converted_contributions_for_lot(lot_id) do
    Repo.all(
      from a in RoomAllocation,
        where:
          a.credit_lot_id == ^lot_id and a.kind == "cash" and
            a.state in ^["converted", "charged_back"],
        group_by: a.source_operation_id,
        select: %{
          source_operation_id: a.source_operation_id,
          amount_cents: sum(a.amount_cents),
          first_position: min(a.position)
        }
    )
    |> Enum.sort_by(& &1.first_position)
  end
end
