defmodule GroupStay.Groups do
  @moduledoc """
  The deposit-keeping context: group reservations, their rooms and room
  allocations, their payments, and the finance ledger totals derived from
  that state.

  Group totals describe the group's active rooms only. Cash and credit fund
  active room deposits through room allocations, in the rooms' original
  order, each funding operation in processing order. Funding from before
  durable operation records is brought forward as one unattributed senior
  block per group, ahead of funding that carries a durable operation record.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Payment
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @held "held"
  @policy_cutoff ~D[2027-01-01]

  def group_exists?(group_id) when is_binary(group_id) do
    Repo.exists?(from g in Group, where: g.group_id == ^group_id)
  end

  @doc """
  Loads a group with its rooms (in their original order) and room
  allocations (in funding order).
  """
  def fetch_by_group_id(group_id) when is_binary(group_id) do
    case Repo.one(from g in Group, where: g.group_id == ^group_id) do
      nil ->
        nil

      group ->
        rooms =
          Repo.all(
            from r in Room, where: r.group_id == ^group.id, order_by: r.position, select: r
          )

        allocations =
          Repo.all(
            from a in Allocation, where: a.group_id == ^group.id, order_by: a.id, select: a
          )

        %{group | rooms: rooms, allocations: allocations}
    end
  end

  @doc """
  The group view returned by the read API.
  """
  def view(%Group{} = group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => refundable_until_iso(group),
      "status" => group.status,
      "rooms" => Enum.map(group.rooms, &room_view(&1, group)),
      "lodging_total_cents" => lodging_total_cents(group),
      "deposit_due_cents" => deposit_due_cents(group),
      "deposit_paid_cents" => deposit_paid_cents(group),
      "cash_paid_cents" => cash_paid_cents(group),
      "credit_paid_cents" => credit_paid_cents(group),
      "outstanding_deposit_cents" => outstanding_deposit_cents(group)
    }
  end

  # The room view: its status, its own deposit requirement, and the cash and
  # credit currently funding it.
  defp room_view(%Room{} = room, %Group{} = group) do
    room_allocations = allocations_of_room(room, group)

    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status,
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => held_cents(room_allocations, "cash"),
      "credit_paid_cents" => held_cents(room_allocations, "credit")
    }
  end

  defp allocations_of_room(%Room{} = room, %Group{allocations: allocations})
       when is_list(allocations),
       do: Enum.filter(allocations, &(&1.room_id == room.id))

  defp allocations_of_room(%Room{} = room, %Group{}),
    do: Repo.all(from a in Allocation, where: a.room_id == ^room.id, select: a)

  defp held_cents(allocations, source) do
    allocations
    |> Enum.filter(&(&1.source == source and &1.state == @held))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  # -- policy versions ---------------------------------------------------------

  @doc """
  The policy version a group receives when it is opened, fixed by its rate
  plan and booking date.
  """
  def policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc "The group's fixed policy version."
  def policy_version(%Group{policy_version: nil} = group),
    do: policy_version_for(group.rate_plan, group.booked_on)

  def policy_version(%Group{policy_version: policy_version}), do: policy_version

  @doc "The cancellation window in days, or nil for a non-refundable policy."
  def cancellation_window("flex-14"), do: 14
  def cancellation_window("flex-30"), do: 30
  def cancellation_window(_), do: nil

  @doc """
  The last date on which cancelling the group is still refundable, or nil
  for a non-refundable policy.
  """
  def refundable_until(%Group{} = group) do
    case cancellation_window(policy_version(group)) do
      nil -> nil
      window -> Date.add(group.arrival_on, -window)
    end
  end

  @doc "`refundable_until` as an ISO 8601 string, or nil."
  def refundable_until_iso(%Group{} = group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  # -- rooms and room totals ------------------------------------------------------

  @doc "The group's active rooms, in their original order."
  def active_rooms(%Group{rooms: rooms}) when is_list(rooms),
    do: Enum.filter(rooms, &(&1.status == "active"))

  def active_rooms(%Group{} = group) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group.id and r.status == "active",
        order_by: r.position
    )
  end

  @doc "A room's lodging amount: the nights of the stay times its nightly rate."
  def room_lodging_cents(%Group{} = group, %Room{} = room),
    do: Date.diff(group.departure_on, group.arrival_on) * room.nightly_rate_cents

  @doc "Total lodging of the group's active rooms."
  def lodging_total_cents(%Group{} = group),
    do: active_rooms(group) |> Enum.map(&room_lodging_cents(group, &1)) |> Enum.sum()

  @doc "Deposit requirement of the group's active rooms."
  def deposit_due_cents(%Group{} = group),
    do: active_rooms(group) |> Enum.map(& &1.deposit_due_cents) |> Enum.sum()

  @doc "Cash currently funding the group's active rooms."
  def cash_paid_cents(%Group{} = group),
    do: held_room_cents(group, "cash")

  @doc "Hotel credit currently funding the group's active rooms."
  def credit_paid_cents(%Group{} = group),
    do: held_room_cents(group, "credit")

  @doc "Total cash and credit currently funding the group's active rooms."
  def deposit_paid_cents(%Group{} = group),
    do: cash_paid_cents(group) + credit_paid_cents(group)

  @doc """
  Deposit still outstanding on an active group: the active rooms'
  requirement minus the cash and credit funding them. Once the group is
  cancelled the unpaid remainder is no longer due.
  """
  def outstanding_deposit_cents(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%Group{} = group) do
    deposit_due_cents(group) - deposit_paid_cents(group)
  end

  # Reads the held funding of the group's active rooms from the loaded
  # allocations, falling back to the database when they are not loaded.
  defp held_room_cents(%Group{} = group, source) do
    room_ids = group |> active_rooms() |> Enum.map(& &1.id)

    case group do
      %Group{allocations: allocations} when is_list(allocations) ->
        allocations
        |> Enum.filter(&(&1.room_id in room_ids and &1.source == source and &1.state == @held))
        |> Enum.map(& &1.amount_cents)
        |> Enum.sum()

      _ ->
        held_cents_in_rooms(room_ids, source)
    end
  end

  defp held_cents_in_rooms(room_ids, source) do
    if room_ids == [] do
      0
    else
      Repo.one(
        from a in Allocation,
          where: a.room_id in ^room_ids and a.source == ^source and a.state == ^@held,
          select: coalesce(sum(a.amount_cents), 0)
      )
      |> normalize_sum()
    end
  end

  # -- allocations ---------------------------------------------------------------

  @doc """
  Held cash allocations of the given rooms, in funding order.
  """
  def held_cash_allocations(group_id, room_ids) do
    held_allocations(group_id, room_ids, "cash")
  end

  @doc """
  Held credit allocations of the given rooms, in funding order.
  """
  def held_credit_allocations(group_id, room_ids) do
    held_allocations(group_id, room_ids, "credit")
  end

  defp held_allocations(group_id, room_ids, source) do
    if room_ids == [] do
      []
    else
      Repo.all(
        from a in Allocation,
          where:
            a.group_id == ^group_id and a.room_id in ^room_ids and a.source == ^source and
              a.state == ^@held,
          order_by: a.id,
          select: a
      )
    end
  end

  @doc """
  Held cash allocations of one payment, in fill order.
  """
  def held_cash_allocations_of_payment(payment_operation_id) do
    Repo.all(
      from a in Allocation,
        where:
          a.source == "cash" and a.operation_id == ^payment_operation_id and a.state == ^@held,
        order_by: a.id,
        select: a
    )
  end

  @doc """
  Applies a funding event to the group's active room deposits.

  `tranches` is the funding in consumption order — one tranche per cash
  payment, or one per credit lot drawn. Allocations fill the active rooms in
  their original order, one room's deposit before the next, each room
  drawing the tranches in order.
  """
  def allocate_funding(%Group{} = group, tranches) do
    rooms = active_rooms(group)

    capacities =
      Enum.map(rooms, fn room ->
        room.deposit_due_cents - held_in_room(room)
      end)

    {allocations, leftover_tranches} = draw_across_rooms(rooms, capacities, tranches, [])

    Enum.each(allocations, &insert_allocation!/1)

    # Funding never exceeds the outstanding deposit, so a leftover means
    # data drift; keep the books balanced by landing it on the last room.
    absorb_leftover(allocations, leftover_tranches)

    :ok
  end

  defp held_in_room(%Room{} = room) do
    Repo.one(
      from a in Allocation,
        where: a.room_id == ^room.id and a.state == ^@held,
        select: coalesce(sum(a.amount_cents), 0)
    )
    |> normalize_sum()
  end

  defp draw_across_rooms([], _capacities, tranches, acc), do: {Enum.reverse(acc), tranches}

  defp draw_across_rooms([room | rooms], [capacity | capacities], tranches, acc) do
    {takes, remaining} = draw_tranches(capacity, tranches, [])

    drawn = Enum.map(takes, &Map.put(&1, :room_id, room.id))
    draw_across_rooms(rooms, capacities, remaining, Enum.reverse(drawn) ++ acc)
  end

  defp draw_tranches(capacity, tranches, acc) when capacity <= 0 or tranches == [],
    do: {Enum.reverse(acc), tranches}

  defp draw_tranches(capacity, [tranche | rest], acc) do
    take = min(tranche.amount_cents, capacity)

    cond do
      # An empty tranche cannot fund anything and is never allocated.
      take == 0 ->
        draw_tranches(capacity, rest, acc)

      take == tranche.amount_cents ->
        draw_tranches(capacity - take, rest, [Map.put(tranche, :amount_cents, take) | acc])

      true ->
        remaining = %{tranche | amount_cents: tranche.amount_cents - take}
        draw_tranches(0, [remaining | rest], [Map.put(tranche, :amount_cents, take) | acc])
    end
  end

  defp insert_allocation!(tranche) do
    %Allocation{}
    |> Allocation.changeset(%{
      group_id: tranche.group_id,
      room_id: tranche.room_id,
      source: tranche.source,
      operation_id: tranche.operation_id,
      lot_id: tranche.lot_id,
      amount_cents: tranche.amount_cents,
      state: Map.get(tranche, :state) || @held
    })
    |> Repo.insert!()
  end

  defp absorb_leftover([], _leftover), do: :ok

  defp absorb_leftover(allocations, leftover) do
    total = leftover |> Enum.map(& &1.amount_cents) |> Enum.sum()

    if total > 0 do
      last = List.last(allocations)

      from(a in Allocation, where: a.id == ^last.id)
      |> Repo.update_all(inc: [amount_cents: total])
    end

    :ok
  end

  @doc """
  Moves cash allocations to their settlement state, linking converted cash
  to the credit lot it created.
  """
  def settle_cash_allocations(allocations, state, lot_id \\ nil) do
    now = utc_now()

    Enum.each(allocations, fn allocation ->
      from(a in Allocation, where: a.id == ^allocation.id)
      |> Repo.update_all(
        set: [state: state, lot_id: lot_id || allocation.lot_id, updated_at: now]
      )
    end)

    :ok
  end

  @doc """
  Removes held cash allocations belonging to a payment in reverse fill
  order until `amount_cents` is reduced, reopening the rooms' outstanding
  deposit. A partially reduced allocation is split so the held remainder
  keeps its place in fill order. Returns the identifiers of every group
  whose funding the reduction changed.
  """
  def reduce_held_cash(allocations, amount_cents) do
    {_remaining, affected} =
      allocations
      |> Enum.reverse()
      |> Enum.reduce_while({amount_cents, MapSet.new()}, fn allocation, {remaining, affected} ->
        cond do
          remaining == 0 ->
            {:halt, {0, affected}}

          allocation.amount_cents <= remaining ->
            set_allocation_state(allocation, "reduced")

            {:cont,
             {remaining - allocation.amount_cents, MapSet.put(affected, allocation.group_id)}}

          true ->
            take = remaining

            from(a in Allocation, where: a.id == ^allocation.id)
            |> Repo.update_all(inc: [amount_cents: -take])

            %Allocation{}
            |> Allocation.changeset(%{
              group_id: allocation.group_id,
              room_id: allocation.room_id,
              source: "cash",
              operation_id: allocation.operation_id,
              lot_id: nil,
              amount_cents: take,
              state: "reduced"
            })
            |> Repo.insert!()

            {:halt, {0, MapSet.put(affected, allocation.group_id)}}
        end
      end)

    MapSet.to_list(affected)
  end

  @doc """
  Moves every disposition of a payment except its already reduced portion
  to charged-back cash, reopening the active rooms' outstanding deposit.
  Returns the amount charged back together with the identifiers of every
  group whose funding changed.
  """
  def charge_back_cash(payment_operation_id) do
    allocations =
      Repo.all(
        from a in Allocation,
          where:
            a.source == "cash" and a.operation_id == ^payment_operation_id and
              a.state != "reduced",
          order_by: a.id,
          select: a
      )

    Enum.each(allocations, &set_allocation_state(&1, "charged_back"))

    charged_back_cents = Enum.sum(Enum.map(allocations, & &1.amount_cents))
    affected = allocations |> MapSet.new(& &1.group_id) |> MapSet.to_list()

    {charged_back_cents, affected}
  end

  @doc """
  Moves `amount_cents` of held funding from one group's active rooms to
  another's. Units are drawn from the source's active-room allocations in
  reverse allocation order — most recently created first, regardless of
  funding kind — and fill the destination's active rooms in their original
  order, preserving the draw order. Each moved unit keeps its provenance:
  cash keeps its payment operation identity and hotel credit keeps its
  original lot. Nothing is settled, revalued, or resumed; the funding
  simply holds different rooms.
  """
  def transfer_funding(%Group{} = source, %Group{} = destination, amount_cents) do
    room_ids = source |> active_rooms() |> Enum.map(& &1.id)

    held =
      if room_ids == [] do
        []
      else
        Repo.all(
          from a in Allocation,
            where: a.group_id == ^source.id and a.room_id in ^room_ids and a.state == ^@held,
            order_by: a.id,
            select: a
        )
      end

    drawn = draw_held_units(Enum.reverse(held), amount_cents, [])

    Enum.each(drawn, fn {allocation, take} ->
      if take == allocation.amount_cents do
        from(a in Allocation, where: a.id == ^allocation.id) |> Repo.delete_all()
      else
        from(a in Allocation, where: a.id == ^allocation.id)
        |> Repo.update_all(inc: [amount_cents: -take])
      end
    end)

    tranches =
      Enum.map(drawn, fn {allocation, take} ->
        %{
          group_id: destination.id,
          source: allocation.source,
          operation_id: allocation.operation_id,
          lot_id: allocation.lot_id,
          amount_cents: take
        }
      end)

    allocate_funding(destination, tranches)

    mark_transferred_payments(drawn)

    :ok
  end

  # Draws `amount_cents` of held funding as {allocation, take} pairs in
  # draw order: reverse allocation order, most recently created first.
  defp draw_held_units(_held, 0, acc), do: Enum.reverse(acc)
  defp draw_held_units([], _remaining, acc), do: Enum.reverse(acc)

  defp draw_held_units([allocation | rest], remaining, acc) do
    take = min(allocation.amount_cents, remaining)
    draw_held_units(rest, remaining - take, [{allocation, take} | acc])
  end

  # A payment whose cash participated in a transfer is marked durably: its
  # statement reports the groups currently holding its cash from then on.
  defp mark_transferred_payments(drawn) do
    operation_ids =
      drawn
      |> Enum.filter(fn {allocation, _take} ->
        allocation.source == "cash" and is_binary(allocation.operation_id)
      end)
      |> Enum.map(fn {allocation, _take} -> allocation.operation_id end)
      |> Enum.uniq()

    if operation_ids != [] do
      now = utc_now()

      from(p in Payment, where: p.operation_id in ^operation_ids)
      |> Repo.update_all(set: [participated_in_transfer: true, updated_at: now])
    end

    :ok
  end

  @doc "A payment's cash allocations grouped by disposition."
  def payment_dispositions(payment_operation_id) do
    rows =
      Repo.all(
        from a in Allocation,
          where: a.source == "cash" and a.operation_id == ^payment_operation_id,
          group_by: a.state,
          select: {a.state, sum(a.amount_cents)}
      )

    states = ~w(held refunded retained converted reduced charged_back)

    Map.new(states, fn state ->
      {state,
       Enum.find_value(rows, fn {row_state, value} ->
         row_state == state && normalize_sum(value)
       end) || 0}
    end)
  end

  @doc "The payment recorded by an operation, if any."
  def fetch_payment_by_operation_id(payment_operation_id) do
    Repo.one(from p in Payment, where: p.operation_id == ^payment_operation_id)
  end

  @doc """
  A payment's held cash grouped by the group currently holding it, ordered
  by `group_id`. Groups holding none of its cash are omitted.
  """
  def payment_held_by_group(payment_operation_id) do
    Repo.all(
      from a in Allocation,
        join: g in Group,
        on: a.group_id == g.id,
        where:
          a.source == "cash" and a.operation_id == ^payment_operation_id and
            a.state == ^@held,
        group_by: g.group_id,
        order_by: g.group_id,
        select: {g.group_id, coalesce(sum(a.amount_cents), 0)}
    )
    |> Enum.map(fn {group_id, value} ->
      %{"group_id" => group_id, "amount_cents" => normalize_sum(value)}
    end)
  end

  defp set_allocation_state(allocation, state) do
    from(a in Allocation, where: a.id == ^allocation.id)
    |> Repo.update_all(set: [state: state, updated_at: utc_now()])

    :ok
  end

  # -- ledger ------------------------------------------------------------------

  @doc """
  Finance totals across all groups, bucketed by the dispositions of the
  cash allocations, plus the hotel-credit liability and current shortfall.
  Expiry is evaluated as of `as_of`.
  """
  def ledger_totals(as_of) do
    %{
      "cash_held_cents" => cash_state_sum("held"),
      "cash_refunded_cents" => cash_state_sum("refunded"),
      "cash_retained_cents" => cash_state_sum("retained"),
      "cash_converted_to_credit_cents" => cash_state_sum("converted"),
      "cash_reduced_cents" => cash_state_sum("reduced"),
      "cash_charged_back_cents" => cash_state_sum("charged_back"),
      "credit_liability_cents" => Credit.liability_cents(as_of),
      "credit_shortfall_cents" => Credit.shortfall_cents()
    }
  end

  defp cash_state_sum(state) do
    Repo.one(
      from a in Allocation,
        where: a.source == "cash" and a.state == ^state,
        select: coalesce(sum(a.amount_cents), 0)
    )
    |> normalize_sum()
  end

  defp normalize_sum(nil), do: 0
  defp normalize_sum(%Decimal{} = value), do: Decimal.to_integer(value)
  defp normalize_sum(value) when is_integer(value), do: value

  # -- writes ------------------------------------------------------------------

  @doc """
  Inserts a group and its rooms in their original order. Returns
  `{:error, :group_already_exists}` when the partner group identifier
  is already taken.
  """
  def create_group(attrs, rooms) do
    %Group{}
    |> Group.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        insert_rooms(group, rooms)
        {:ok, group}

      {:error, _changeset} ->
        {:error, :group_already_exists}
    end
  end

  defp insert_rooms(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, index} ->
      %Room{}
      |> Room.changeset(%{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        deposit_due_cents: room.deposit_due_cents,
        status: "active",
        position: index
      })
      |> Repo.insert!()
    end)
  end

  @doc """
  Records cash applied to a group's deposit and allocates it to the group's
  active rooms.
  """
  def create_payment(group, amount_cents, recorded_on, operation_id) do
    with {:ok, payment} <-
           %Payment{}
           |> Payment.changeset(%{
             group_id: group.id,
             operation_id: operation_id,
             amount_cents: amount_cents,
             recorded_on: recorded_on
           })
           |> Repo.insert(),
         :ok <-
           allocate_funding(group, [
             %{
               group_id: group.id,
               source: "cash",
               operation_id: operation_id,
               lot_id: nil,
               amount_cents: amount_cents
             }
           ]) do
      {:ok, payment}
    end
  end

  @doc """
  Cancels the given rooms: their deposit ceases to be due and the group's
  totals drop to its remaining active rooms. The caller decides the
  settlement of the rooms' allocations.
  """
  def cancel_rooms(%Group{} = group, rooms) do
    now = utc_now()

    Enum.each(rooms, fn room ->
      from(r in Room, where: r.id == ^room.id)
      |> Repo.update_all(set: [status: "cancelled", updated_at: now])
    end)

    cancelled_ids = MapSet.new(rooms, & &1.id)
    remaining = Enum.reject(group.rooms, &(&1.id in cancelled_ids))
    remaining_active = Enum.filter(remaining, &(&1.status == "active"))

    lodging = Enum.sum(Enum.map(remaining_active, &room_lodging_cents(group, &1)))
    due = Enum.sum(Enum.map(remaining_active, & &1.deposit_due_cents))

    from(g in Group, where: g.id == ^group.id)
    |> Repo.update_all(
      set: [lodging_total_cents: lodging, deposit_due_cents: due, updated_at: now]
    )

    updated_rooms =
      Enum.map(
        group.rooms,
        &if(&1.id in cancelled_ids, do: %{&1 | status: "cancelled"}, else: &1)
      )

    updated = %{
      group
      | rooms: updated_rooms,
        lodging_total_cents: lodging,
        deposit_due_cents: due
    }

    {:ok, updated, remaining_active}
  end

  @doc """
  Bumps the group's revision — optionally applying further changes in the
  same guarded update — or returns `{:error, :stale}` when the group changed
  concurrently.
  """
  def apply_revision(%Group{} = group, changes \\ []) do
    now = utc_now()
    sets = Keyword.merge(changes, revision: group.revision + 1, updated_at: now)

    from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision)
    |> Repo.update_all(set: sets)
    |> case do
      {1, _} ->
        {:ok, %{group | revision: group.revision + 1}}

      {_, _} ->
        {:error, :stale}
    end
  end

  @doc """
  Bumps the group's revision, returning the new revision, or `{:error, :stale}`
  when the group changed concurrently.
  """
  def bump_revision(group) do
    case apply_revision(group) do
      {:ok, updated} -> {:ok, updated.revision}
      {:error, :stale} -> {:error, :stale}
    end
  end

  @doc """
  Shifts the group's stay dates, bumping its revision. The revision guard
  makes the update fail with `{:error, :stale}` when the group changed
  concurrently.
  """
  def reschedule_group(group, arrival_on, departure_on) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision)
    |> Repo.update_all(
      set: [
        arrival_on: arrival_on,
        departure_on: departure_on,
        revision: group.revision + 1,
        updated_at: now
      ]
    )
    |> case do
      {1, _} ->
        {:ok,
         %{
           group
           | arrival_on: arrival_on,
             departure_on: departure_on,
             revision: group.revision + 1
         }}

      {_, _} ->
        {:error, :stale}
    end
  end

  @doc "The group's current revision, re-read from the database."
  def current_revision(group_id) do
    case Repo.one(from g in Group, where: g.group_id == ^group_id, select: g.revision) do
      nil -> 0
      revision -> revision
    end
  end

  defp utc_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
