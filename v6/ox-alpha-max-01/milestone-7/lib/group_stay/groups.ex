defmodule GroupStay.Groups do
  @moduledoc """
  Applies group-deposit operations: opening, funding, moving, cancelling
  whole groups or selected rooms, plus reading a group with its current
  totals.

  Every applied operation addressed to an existing group increments the
  group's revision exactly once. Rejected operations leave the groups,
  rooms, credit, and ledger exactly as they were.

  The mutating functions take part in the caller's `Repo.transaction` and
  never begin one themselves, so a partner operation's domain changes and
  its durable idempotency record always commit together. Validation follows
  a fixed order: group existence, expected revision, active state, then the
  operation's own rules.

  Cash and hotel credit fund active rooms in their original order through
  `GroupStay.Fundings`; a group's money totals describe its active rooms.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Finance
  alias GroupStay.Fundings
  alias GroupStay.Groups.Funding
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Ledger
  alias GroupStay.Policy
  alias GroupStay.Repo

  @flexible_deposit_percent 20

  @type reason ::
          :group_already_exists
          | :invalid_stay
          | :invalid_rooms
          | :invalid_rate_plan
          | :group_not_found
          | :group_not_active
          | :invalid_amount
          | :payment_exceeds_outstanding
          | :refund_method_not_available
          | :insufficient_credit

  @doc """
  Opens a new group reservation at revision 1.

  `attrs` requires `group_id`, `booked_on`, `arrival_on`, `departure_on`,
  `rate_plan` (dates as `Date` structs), accepts optional `guest_id` and
  `property_id`, and requires `rooms` as a list of maps with `room_id` and
  `nightly_rate_cents`. Returns `{:error, reason}` without writing anything
  when the reservation is invalid.
  """
  def open_group(attrs) do
    group_id = Keyword.fetch!(attrs, :group_id)
    arrival = Keyword.fetch!(attrs, :arrival_on)
    departure = Keyword.fetch!(attrs, :departure_on)
    rooms = Keyword.get(attrs, :rooms, [])

    cond do
      group_exists?(group_id) ->
        {:error, :group_already_exists}

      Date.diff(departure, arrival) < 1 ->
        {:error, :invalid_stay}

      not valid_rooms?(rooms) ->
        {:error, :invalid_rooms}

      Keyword.fetch!(attrs, :rate_plan) not in Group.rate_plans() ->
        {:error, :invalid_rate_plan}

      true ->
        insert_open_group(attrs, group_id, arrival, departure, rooms)
    end
  end

  @doc """
  Applies cash to an active group's outstanding deposit, allocating it
  across the active rooms in their original order.

  Returns the new revision and remaining outstanding deposit.
  """
  def record_cash_payment(group_id, amount_cents, opts \\ []) do
    expected_revision = Keyword.get(opts, :expected_revision)
    operation_id = Keyword.get(opts, :operation_id)
    occurred_on = Keyword.get(opts, :occurred_on)

    with {:ok, group} <- load_active_group(group_id, expected_revision),
         :ok <- validate_amount(amount_cents) do
      outstanding = outstanding_cents(group)

      if amount_cents <= outstanding do
        {:ok, _entry} = Ledger.record_payment(group.id, amount_cents, operation_id: operation_id)
        _fundings = Fundings.allocate_cash(group, amount_cents, operation_id)

        Finance.record_cash(
          Finance.posting(occurred_on),
          group.property_id,
          :received_cents,
          amount_cents
        )

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding - amount_cents,
           revision: bump_revision!(group)
         }}
      else
        {:error, :payment_exceeds_outstanding}
      end
    end
  end

  @doc """
  Moves an active group so it arrives on `new_arrival_on`. The departure date
  shifts by the same number of calendar days, keeping the stay length and all
  money unchanged. The new arrival must be after `occurred_on`. The group's
  fixed policy version is never moved to a newer policy; only the recomputed
  refundable date follows the new arrival.
  """
  def reschedule_group(group_id, new_arrival_on, occurred_on, expected_revision \\ nil) do
    with {:ok, group} <- load_active_group(group_id, expected_revision) do
      if arrival_after_occurred?(new_arrival_on, occurred_on) do
        shift = Date.diff(new_arrival_on, group.arrival_on)
        new_departure_on = Date.add(group.departure_on, shift)

        {:ok, group} =
          group
          |> Group.changeset(%{arrival_on: new_arrival_on, departure_on: new_departure_on})
          |> Repo.update()

        {:ok,
         %{
           group_id: group.group_id,
           new_arrival_on: group.arrival_on,
           new_departure_on: group.departure_on,
           policy_version: group.policy_version,
           refundable_until: Group.refundable_until(group),
           revision: bump_revision!(group)
         }}
      else
        {:error, :invalid_stay}
      end
    end
  end

  @doc """
  Cancels an active group under its fixed policy version, settling every
  remaining active room.

  Refundable flexible cancellations settle the settled rooms' allocated cash
  according to `refund_method` (`:cash` by default, or `:hotel_credit`):
  cash is refunded, or it becomes a credit lot worth 110% of the cash,
  available through 365 days after cancellation and expiring the following
  day. Converted cash is neither refunded nor retained. Credit the group
  received from earlier `apply_hotel_credit` operations returns to its
  original lots with their original expiry either way.

  Non-refundable cancellations retain the allocated cash and consume applied
  credit. Unpaid deposit is no longer due. A `:hotel_credit` request for a
  non-refundable cancellation is rejected with `:refund_method_not_available`
  and leaves the group active.
  """
  def cancel_group(group_id, occurred_on, opts \\ []) do
    {expected_revision, opts} = Keyword.pop(opts, :expected_revision)
    {refund_method, opts} = Keyword.pop(opts, :refund_method, :cash)
    {source_operation_id, _opts} = Keyword.pop(opts, :source_operation_id)

    with {:ok, group} <- load_active_group(group_id, expected_revision),
         refundable = Policy.refundable?(group.policy_version, group.arrival_on, occurred_on),
         :ok <- ensure_refund_method(refundable, refund_method) do
      rooms = Fundings.active_rooms(group.id)

      {refunded, retained, issued} =
        settle_rooms(group, rooms, refundable, refund_method, source_operation_id, occurred_on)

      finish_cancel(group, refunded, retained, issued)
    end
  end

  @doc """
  Cancels selected distinct active rooms of an active group, settling each
  room's allocated cash and credit with the same date, policy, refund
  method, bonus, and restoration rules as a full cancellation. Unpaid
  deposit for those rooms ceases to be due; other rooms and their
  allocations are untouched. The group becomes `cancelled` when no active
  rooms remain.
  """
  def cancel_rooms(group_id, room_ids, occurred_on, opts \\ []) do
    {expected_revision, opts} = Keyword.pop(opts, :expected_revision)
    {refund_method, opts} = Keyword.pop(opts, :refund_method, :cash)
    {source_operation_id, _opts} = Keyword.pop(opts, :source_operation_id)

    with {:ok, group} <- load_active_group(group_id, expected_revision),
         {:ok, rooms} <- resolve_cancellable_rooms(group, room_ids),
         refundable = Policy.refundable?(group.policy_version, group.arrival_on, occurred_on),
         :ok <- ensure_refund_method(refundable, refund_method) do
      {refunded, retained, issued} =
        settle_rooms(group, rooms, refundable, refund_method, source_operation_id, occurred_on)

      group = maybe_cancel_group(group)

      {:ok,
       %{
         group_id: group.group_id,
         # Reported in the group's original room order, whatever order the
         # caller supplied.
         cancelled_room_ids: rooms |> Enum.sort_by(& &1.position) |> Enum.map(& &1.room_id),
         refunded_cents: refunded,
         retained_cents: retained,
         credit_issued_cents: issued,
         revision: bump_revision!(group)
       }}
    end
  end

  @doc """
  Redeems the guest's hotel credit into an active group's outstanding
  deposit.

  Lots are consumed earliest expiry first, then by source operation, as of
  `occurred_on`. Applying credit pauses the consumed amounts' expiry while
  they fund the group's active rooms.
  """
  def apply_hotel_credit(group_id, amount_cents, occurred_on, opts \\ []) do
    expected_revision = Keyword.get(opts, :expected_revision)
    operation_id = Keyword.get(opts, :operation_id)

    with {:ok, group} <- load_active_group(group_id, expected_revision),
         :ok <- validate_amount(amount_cents),
         :ok <- ensure_unexpired_credit(group, amount_cents, occurred_on) do
      outstanding = outstanding_cents(group)

      if amount_cents <= outstanding do
        _fundings = Credit.apply_to_group(group, amount_cents, occurred_on, operation_id)

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding - amount_cents,
           revision: bump_revision!(group)
         }}
      else
        {:error, :payment_exceeds_outstanding}
      end
    end
  end

  @doc """
  Reads a group with its rooms in original order and its current totals, or
  `:not_found`. Totals describe active rooms only; each room carries its own
  lodging amount, deposit requirement, status, and held cash and credit.
  """
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        :not_found

      group ->
        nights = Date.diff(group.departure_on, group.arrival_on)
        per_room = Fundings.held_per_room(group.id)

        room_views =
          group.id
          |> Fundings.rooms()
          |> Enum.map(fn room ->
            used = Map.get(per_room, room.id, %{cash: 0, credit: 0})

            room
            |> Map.from_struct()
            |> Map.merge(%{
              lodging_cents: room_lodging_cents(room, nights),
              cash_paid_cents: used.cash,
              credit_paid_cents: used.credit
            })
          end)

        active = Enum.filter(room_views, &(&1.status == "active"))

        lodging_total_cents = sum_view(active, :lodging_cents)
        deposit_due_cents = sum_view(active, :deposit_due_cents)
        cash_paid_cents = sum_view(active, :cash_paid_cents)
        credit_paid_cents = sum_view(active, :credit_paid_cents)
        deposit_paid_cents = cash_paid_cents + credit_paid_cents

        {:ok,
         %{
           group: group,
           rooms: room_views,
           totals: %{
             lodging_total_cents: lodging_total_cents,
             deposit_due_cents: deposit_due_cents,
             deposit_paid_cents: deposit_paid_cents,
             outstanding_deposit_cents: max(deposit_due_cents - deposit_paid_cents, 0),
             cash_paid_cents: cash_paid_cents,
             credit_paid_cents: credit_paid_cents
           }
         }}
    end
  end

  @doc """
  The deposit requirement not yet satisfied by cash or applied hotel credit
  across the group's active rooms.
  """
  def outstanding_cents(%Group{} = group) do
    capacities =
      group.id
      |> Fundings.active_rooms()
      |> Enum.reduce(0, fn room, total -> total + (room.deposit_due_cents || 0) end)

    paid =
      Fundings.group_held_cents(group.id, "cash") +
        Fundings.group_held_cents(group.id, "credit")

    max(capacities - paid, 0)
  end

  @doc """
  Increments the group's revision exactly once, returning the new value.
  Participates in the caller's transaction.
  """
  def bump_revision!(%Group{} = group) do
    {1, _} =
      from(g in Group, where: g.id == ^group.id)
      |> Repo.update_all(inc: [revision: 1])

    group.revision + 1
  end

  @doc """
  Increments each named group's revision exactly once — an applied operation
  bumps every group whose state it changes plus the group it is addressed
  to. Returns a map of internal group id to its new revision.
  """
  def bump_revisions!(group_ids) do
    ids = Enum.uniq(group_ids)

    from(g in Group, where: g.id in ^ids)
    |> Repo.update_all(inc: [revision: 1])

    from(g in Group, where: g.id in ^ids, select: {g.id, g.revision})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The lodging amount for one room: number of nights multiplied by its nightly
  rate.
  """
  def room_lodging_cents(%{nightly_rate_cents: rate}, nights), do: rate * nights

  @doc """
  The group's deposit requirement: flexible rooms contribute a rounded
  #{@flexible_deposit_percent}% of their own lodging amount; advance-purchase rooms contribute
  their full lodging amount.
  """
  def deposit_due_cents("flexible", rooms, nights) do
    rooms
    |> Enum.map(&percent_of(room_lodging_cents(&1, nights), @flexible_deposit_percent))
    |> Enum.sum()
  end

  def deposit_due_cents("advance_purchase", rooms, nights) do
    rooms
    |> Enum.map(&room_lodging_cents(&1, nights))
    |> Enum.sum()
  end

  @doc """
  Percentage of an integer cent amount, rounded to the nearest cent with an
  exact half-cent rounding upward.
  """
  def percent_of(amount_cents, percent) do
    div(amount_cents * percent + 50, 100)
  end

  defp insert_open_group(attrs, group_id, arrival, departure, rooms) do
    rate_plan = Keyword.fetch!(attrs, :rate_plan)
    booked_on = Keyword.fetch!(attrs, :booked_on)
    nights = Date.diff(departure, arrival)

    {:ok, group} =
      %Group{}
      |> Group.changeset(%{
        group_id: group_id,
        guest_id: Keyword.get(attrs, :guest_id),
        property_id: Keyword.get(attrs, :property_id),
        revision: 1,
        status: "active",
        rate_plan: rate_plan,
        policy_version: Policy.version_for(rate_plan, booked_on),
        booked_on: booked_on,
        arrival_on: arrival,
        departure_on: departure,
        deposit_due_cents: deposit_due_cents(rate_plan, rooms, nights)
      })
      |> Repo.insert()

    rooms =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        {:ok, room} =
          %Room{}
          |> Room.changeset(%{
            group_id: group.id,
            position: position,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: "active",
            deposit_due_cents: room_deposit_due_cents(rate_plan, room, nights)
          })
          |> Repo.insert()

        room
      end)

    {:ok, %{group | rooms: rooms}}
  end

  defp room_deposit_due_cents("flexible", room, nights) do
    percent_of(room_lodging_cents(room, nights), @flexible_deposit_percent)
  end

  defp room_deposit_due_cents("advance_purchase", room, nights) do
    room_lodging_cents(room, nights)
  end

  # Settles the given rooms' allocated cash and credit. Cash dispositions are
  # attributed back to their contributing payments; the unattributed legacy
  # block settles as one senior source. A hotel-credit settlement computes
  # the bonus once over the combined cash and issues a single lot. Every
  # disposition posts to the settling group's property at the operation's
  # reporting posting date.
  defp settle_rooms(_group, [], _refundable?, _refund_method, _source_operation_id, _occurred_on),
    do: {0, 0, 0}

  defp settle_rooms(group, rooms, refundable?, refund_method, source_operation_id, occurred_on) do
    room_ids = Enum.map(rooms, & &1.id)
    posting = Finance.posting(occurred_on)
    property_id = group.property_id
    cash_fundings = Fundings.cash_fundings_for_rooms(room_ids)
    credit_fundings = Fundings.credit_fundings_for_rooms(room_ids)
    sources = ordered_cash_sources(cash_fundings)
    combined_cash = Enum.sum(Enum.map(sources, fn {_op, cents} -> cents end))

    {refunded, retained, issued} =
      cond do
        not refundable? ->
          Enum.each(sources, fn {operation_id, cents} ->
            {:ok, _} = Ledger.record_retention(group.id, cents, operation_id: operation_id)
            Finance.record_cash(posting, property_id, :retained_cents, cents)
          end)

          :ok = Credit.consume_fundings(credit_fundings, posting)
          {0, combined_cash, 0}

        refund_method == :hotel_credit ->
          Enum.each(sources, fn {operation_id, cents} ->
            {:ok, _} =
              Ledger.record_credit_conversion(group.id, cents, operation_id: operation_id)

            Finance.record_cash(posting, property_id, :converted_to_credit_cents, cents)
          end)

          {issued, lot} =
            Credit.issue_lot_for_sources(
              group.guest_id,
              source_operation_id,
              sources,
              occurred_on
            )

          Finance.record_credit(posting, lot && lot.id, :issued_cents, issued)

          :ok = Credit.restore_fundings(credit_fundings, posting)
          {0, 0, issued}

        true ->
          Enum.each(sources, fn {operation_id, cents} ->
            {:ok, _} = Ledger.record_refund(group.id, cents, operation_id: operation_id)
            Finance.record_cash(posting, property_id, :refunded_cents, cents)
          end)

          :ok = Credit.restore_fundings(credit_fundings, posting)
          {combined_cash, 0, 0}
      end

    delete_all(Funding, cash_fundings)
    mark_rooms_cancelled(rooms)

    {refunded, retained, issued}
  end

  # Groups the rooms' cash fundings by contributing operation, preserving
  # fill order: the unattributed legacy block leads, durable payments follow
  # in commit order.
  defp ordered_cash_sources(cash_fundings) do
    {order, amounts} =
      Enum.reduce(cash_fundings, {[], %{}}, fn funding, {order, amounts} ->
        if Map.has_key?(amounts, funding.operation_id) do
          {order, Map.update!(amounts, funding.operation_id, &(&1 + funding.amount_cents))}
        else
          {order ++ [funding.operation_id],
           Map.put(amounts, funding.operation_id, funding.amount_cents)}
        end
      end)

    Enum.map(order, fn operation_id -> {operation_id, Map.fetch!(amounts, operation_id)} end)
  end

  defp resolve_cancellable_rooms(group, room_ids) do
    well_formed? =
      is_list(room_ids) and room_ids != [] and Enum.all?(room_ids, &is_binary/1) and
        Enum.uniq(room_ids) == room_ids

    by_room_id = Map.new(Fundings.rooms(group.id), fn room -> {room.room_id, room} end)

    cond do
      not well_formed? ->
        {:error, :invalid_rooms}

      not Enum.all?(room_ids, &Map.has_key?(by_room_id, &1)) ->
        {:error, :invalid_rooms}

      true ->
        rooms = Enum.map(room_ids, &Map.fetch!(by_room_id, &1))

        if Enum.all?(rooms, &Room.active?/1) do
          {:ok, rooms}
        else
          {:error, :invalid_rooms}
        end
    end
  end

  defp ensure_refund_method(true = _refundable, _method), do: :ok

  defp ensure_refund_method(false = _refundable, :cash), do: :ok

  defp ensure_refund_method(false = _refundable, :hotel_credit),
    do: {:error, :refund_method_not_available}

  # A partial cancellation leaves the group open while any active room
  # remains; cancelling the final active room closes the whole group.
  defp maybe_cancel_group(group) do
    if Fundings.active_rooms(group.id) == [] do
      {:ok, group} =
        group
        |> Group.changeset(%{status: "cancelled"})
        |> Repo.update()

      group
    else
      group
    end
  end

  defp mark_rooms_cancelled(rooms) do
    from(r in Room, where: r.id in ^Enum.map(rooms, & &1.id))
    |> Repo.update_all(set: [status: "cancelled"])

    :ok
  end

  defp delete_all(schema, rows) do
    if rows != [] do
      {_count, _} =
        from(f in schema, where: f.id in ^Enum.map(rows, & &1.id))
        |> Repo.delete_all()

      :ok
    else
      :ok
    end
  end

  defp finish_cancel(group, refunded_cents, retained_cents, credit_issued_cents) do
    {:ok, group} =
      group
      |> Group.changeset(%{status: "cancelled"})
      |> Repo.update()

    {:ok,
     %{
       group_id: group.group_id,
       refunded_cents: refunded_cents,
       retained_cents: retained_cents,
       credit_issued_cents: credit_issued_cents,
       revision: bump_revision!(group)
     }}
  end

  # Existence, then expected revision, then active state.
  defp load_active_group(group_id, expected_revision) do
    with {:ok, group} <- load_group(group_id),
         :ok <- check_revision(group, expected_revision),
         :ok <- ensure_active(group) do
      {:ok, group}
    end
  end

  defp load_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp check_revision(_group, nil), do: :ok

  defp check_revision(group, expected_revision) do
    if expected_revision == group.revision,
      do: :ok,
      else: {:error, {:stale_revision, expected_revision, group.revision}}
  end

  defp ensure_active(group),
    do: if(Group.active?(group), do: :ok, else: {:error, :group_not_active})

  defp validate_amount(amount),
    do: if(usable_amount?(amount), do: :ok, else: {:error, :invalid_amount})

  defp ensure_unexpired_credit(group, amount_cents, occurred_on) do
    if Credit.available_cents(group.guest_id, occurred_on) >= amount_cents,
      do: :ok,
      else: {:error, :insufficient_credit}
  end

  defp arrival_after_occurred?(new_arrival_on, occurred_on),
    do: Date.compare(new_arrival_on, occurred_on) == :gt

  defp usable_amount?(amount), do: is_integer(amount) and amount > 0

  defp sum_view(views, key) do
    views
    |> Enum.map(&(&1[key] || 0))
    |> Enum.sum()
  end

  defp valid_rooms?(rooms) do
    is_list(rooms) and rooms != [] and
      Enum.all?(rooms, fn room ->
        room_id = safe(room, :room_id)
        nightly_rate_cents = safe(room, :nightly_rate_cents)

        is_map(room) and is_binary(room_id) and room_id != "" and
          is_integer(nightly_rate_cents) and nightly_rate_cents > 0
      end) and
      Enum.uniq_by(rooms, & &1.room_id) == rooms
  end

  defp safe(map, key) when is_map(map), do: Map.get(map, key)
  defp safe(_other, _key), do: nil

  defp group_exists?(group_id), do: Repo.exists?(from(g in Group, where: g.group_id == ^group_id))
end
