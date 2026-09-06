defmodule GroupStay.Groups do
  @moduledoc """
  Applies group-deposit operations: opening, funding, moving, and cancelling
  group reservations, plus reading a group with its current totals.

  Every applied operation addressed to an existing group increments the
  group's revision exactly once. Rejected operations leave the groups,
  rooms, credit, and ledger exactly as they were.

  The mutating functions take part in the caller's `Repo.transaction` and
  never begin one themselves, so a partner operation's domain changes and
  its durable idempotency record always commit together. Validation follows
  a fixed order: group existence, expected revision, active state, then the
  operation's own rules.
  """

  import Ecto.Query

  alias GroupStay.Credit
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
  Applies cash to an active group's outstanding deposit.

  Returns the new revision and remaining outstanding deposit.
  """
  def record_cash_payment(group_id, amount_cents, expected_revision \\ nil) do
    with {:ok, group} <- load_active_group(group_id, expected_revision),
         :ok <- validate_amount(amount_cents) do
      outstanding = outstanding_cents(group)

      if amount_cents <= outstanding do
        {:ok, _entry} = Ledger.record_payment(group.id, amount_cents)

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
  Cancels an active group under its fixed policy version.

  Refundable flexible cancellations settle the paid cash according to
  `refund_method` (`:cash` by default, or `:hotel_credit`): cash is refunded,
  or it becomes a credit lot worth 110% of the cash, available through 365
  days after cancellation and expiring the following day. Converted cash is
  neither refunded nor retained. Credit the group received from earlier
  `apply_hotel_credit` operations returns to its original lots with their
  original expiry either way.

  Non-refundable cancellations retain paid cash and consume applied credit.
  Unpaid deposit is no longer due. A `:hotel_credit` request for a
  non-refundable cancellation is rejected with `:refund_method_not_available`
  and leaves the group active.
  """
  def cancel_group(group_id, occurred_on, opts \\ []) do
    {expected_revision, opts} = Keyword.pop(opts, :expected_revision)
    {refund_method, opts} = Keyword.pop(opts, :refund_method, :cash)
    {source_operation_id, _opts} = Keyword.pop(opts, :source_operation_id)

    with {:ok, group} <- load_active_group(group_id, expected_revision) do
      refundable? = Policy.refundable?(group.policy_version, group.arrival_on, occurred_on)

      if refund_method == :hotel_credit and not refundable? do
        {:error, :refund_method_not_available}
      else
        settle_cancelled_group(
          group,
          refundable?,
          refund_method,
          source_operation_id,
          occurred_on
        )
      end
    end
  end

  @doc """
  Redeems the guest's hotel credit into an active group's outstanding
  deposit.

  Lots are consumed earliest expiry first, then by source operation, as of
  `occurred_on`. Applying credit pauses the consumed amounts' expiry while
  they fund the group.
  """
  def apply_hotel_credit(group_id, amount_cents, occurred_on, expected_revision \\ nil) do
    with {:ok, group} <- load_active_group(group_id, expected_revision),
         :ok <- validate_amount(amount_cents),
         :ok <- ensure_unexpired_credit(group, amount_cents, occurred_on) do
      outstanding = outstanding_cents(group)

      if amount_cents <= outstanding do
        {:ok, _fundings} = Credit.apply_to_group(group, amount_cents, occurred_on)

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
  `:not_found`.
  """
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        :not_found

      group ->
        rooms =
          from(r in Room, where: r.group_id == ^group.id, order_by: r.position)
          |> Repo.all()

        sums = Ledger.sums_for_group(group.id)
        cash_paid_cents = paid_cents(sums)
        credit_paid_cents = Credit.applied_cents(group.id)
        nights = Date.diff(group.departure_on, group.arrival_on)
        lodging_total_cents = Enum.sum(Enum.map(rooms, &room_lodging_cents(&1, nights)))

        {:ok,
         %{
           group: group,
           rooms: rooms,
           totals: %{
             lodging_total_cents: lodging_total_cents,
             deposit_due_cents: group.deposit_due_cents,
             deposit_paid_cents: cash_paid_cents + credit_paid_cents,
             outstanding_deposit_cents:
               if Group.active?(group) do
                 max(group.deposit_due_cents - cash_paid_cents - credit_paid_cents, 0)
               else
                 0
               end,
             cash_paid_cents: cash_paid_cents,
             credit_paid_cents: credit_paid_cents
           }
         }}
    end
  end

  @doc """
  Cash applied to the group's deposit and not yet settled by cancellation.
  """
  def paid_cents(%Group{} = group) do
    paid_cents(Ledger.sums_for_group(group.id))
  end

  def paid_cents(sums) when is_map(sums) do
    sums.payment - sums.refund - sums.retention - sums.credit_conversion
  end

  @doc """
  The deposit requirement not yet satisfied by cash or applied hotel credit.
  """
  def outstanding_cents(%Group{} = group) do
    max(group.deposit_due_cents - paid_cents(group) - Credit.applied_cents(group.id), 0)
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
            nightly_rate_cents: room.nightly_rate_cents
          })
          |> Repo.insert()

        room
      end)

    {:ok, %{group | rooms: rooms}}
  end

  defp settle_cancelled_group(group, refundable?, refund_method, source_operation_id, occurred_on) do
    cash_paid = paid_cents(group)

    cond do
      not refundable? ->
        if cash_paid > 0, do: {:ok, _} = Ledger.record_retention(group.id, cash_paid)
        :ok = Credit.consume_for_group(group.id)
        finish_cancel(group, 0, cash_paid, 0)

      refund_method == :hotel_credit ->
        if cash_paid > 0, do: {:ok, _} = Ledger.record_credit_conversion(group.id, cash_paid)

        {issued, _lot} =
          Credit.issue_lot(group.guest_id, source_operation_id, cash_paid, occurred_on)

        :ok = Credit.restore_for_group(group.id)
        finish_cancel(group, 0, 0, issued)

      true ->
        if cash_paid > 0, do: {:ok, _} = Ledger.record_refund(group.id, cash_paid)
        :ok = Credit.restore_for_group(group.id)
        finish_cancel(group, cash_paid, 0, 0)
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

  defp bump_revision!(group) do
    {1, _} =
      from(g in Group, where: g.id == ^group.id)
      |> Repo.update_all(inc: [revision: 1])

    group.revision + 1
  end

  defp arrival_after_occurred?(new_arrival_on, occurred_on),
    do: Date.compare(new_arrival_on, occurred_on) == :gt

  defp usable_amount?(amount), do: is_integer(amount) and amount > 0

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
