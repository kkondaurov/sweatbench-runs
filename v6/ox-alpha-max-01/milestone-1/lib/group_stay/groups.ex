defmodule GroupStay.Groups do
  @moduledoc """
  Applies group-deposit operations: opening, funding, moving, and cancelling
  group reservations, plus reading a group with its current totals.

  Every applied operation addressed to an existing group increments the
  group's revision exactly once. Rejected operations leave the database
  exactly as it was.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Ledger
  alias GroupStay.Repo

  @flexible_deposit_percent 20

  @refundable_days_before_arrival 14

  @type reason ::
          :group_already_exists
          | :invalid_stay
          | :invalid_rooms
          | :invalid_rate_plan
          | :group_not_found
          | :group_not_active
          | :invalid_amount
          | :payment_exceeds_outstanding

  @doc """
  Opens a new group reservation at revision 1.

  `attrs` requires `group_id`, `booked_on`, `arrival_on`, `departure_on`,
  `rate_plan` (dates as `Date` structs), accepts optional `guest_id` and
  `property_id`, and requires `rooms` as a list of maps with `room_id` and
  `nightly_rate_cents`.
  """
  def open_group(attrs) do
    Repo.transaction(fn ->
      group_id = Keyword.fetch!(attrs, :group_id)

      if group_exists?(group_id),
        do: Repo.rollback(:group_already_exists)

      arrival = Keyword.fetch!(attrs, :arrival_on)
      departure = Keyword.fetch!(attrs, :departure_on)
      rooms = Keyword.get(attrs, :rooms, [])

      nights = Date.diff(departure, arrival)
      nights >= 1 or Repo.rollback(:invalid_stay)
      valid_rooms?(rooms) or Repo.rollback(:invalid_rooms)

      rate_plan = Keyword.fetch!(attrs, :rate_plan)
      rate_plan in Group.rate_plans() or Repo.rollback(:invalid_rate_plan)

      deposit_due_cents = deposit_due_cents(rate_plan, rooms, nights)

      {:ok, group} =
        %Group{}
        |> Group.changeset(%{
          group_id: group_id,
          guest_id: Keyword.get(attrs, :guest_id),
          property_id: Keyword.get(attrs, :property_id),
          revision: 1,
          status: "active",
          rate_plan: rate_plan,
          booked_on: Keyword.fetch!(attrs, :booked_on),
          arrival_on: arrival,
          departure_on: departure,
          deposit_due_cents: deposit_due_cents
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

      %{group | rooms: rooms}
    end)
    |> unwrap()
  end

  @doc """
  Applies cash to an active group's outstanding deposit.

  Validation order: existence, expected revision, active state, amount
  usability, outstanding limit. Returns the new revision and remaining
  outstanding deposit.
  """
  def record_cash_payment(group_id, amount_cents, expected_revision \\ nil) do
    in_transaction(group_id, expected_revision, fn group ->
      usable_amount?(amount_cents) or Repo.rollback({:error, :invalid_amount})

      paid = paid_cents(group)
      outstanding = max(group.deposit_due_cents - paid, 0)
      amount_cents <= outstanding or Repo.rollback({:error, :payment_exceeds_outstanding})

      {:ok, _entry} = Ledger.record_payment(group.id, amount_cents)

      revision = bump_revision!(group)

      %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding - amount_cents,
        revision: revision
      }
    end)
  end

  @doc """
  Moves an active group so it arrives on `new_arrival_on`. The departure date
  shifts by the same number of calendar days, keeping the stay length and all
  money unchanged. The new arrival must be after `occurred_on`.
  """
  def reschedule_group(group_id, new_arrival_on, occurred_on, expected_revision \\ nil) do
    in_transaction(group_id, expected_revision, fn group ->
      arrival_after_occurred?(new_arrival_on, occurred_on) or
        Repo.rollback({:error, :invalid_stay})

      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      {:ok, group} =
        group
        |> Group.changeset(%{arrival_on: new_arrival_on, departure_on: new_departure_on})
        |> Repo.update()

      revision = bump_revision!(group)

      %{
        group_id: group.group_id,
        new_arrival_on: group.arrival_on,
        new_departure_on: group.departure_on,
        revision: revision
      }
    end)
  end

  @doc """
  Cancels an active group. Flexible reservations refund their paid cash when
  cancellation occurs at least #{@refundable_days_before_arrival} calendar days before arrival;
  otherwise the cash is retained. Advance-purchase reservations always retain
  their cash. Unpaid deposit is no longer due.
  """
  def cancel_group(group_id, occurred_on, expected_revision \\ nil) do
    in_transaction(group_id, expected_revision, fn group ->
      paid = paid_cents(group)

      {refunded_cents, retained_cents} =
        if refundable?(group, occurred_on), do: {paid, 0}, else: {0, paid}

      if refunded_cents > 0 do
        {:ok, _entry} = Ledger.record_refund(group.id, refunded_cents)
      end

      if retained_cents > 0 do
        {:ok, _entry} = Ledger.record_retention(group.id, retained_cents)
      end

      {:ok, group} =
        group
        |> Group.changeset(%{status: "cancelled"})
        |> Repo.update()

      revision = bump_revision!(group)

      %{
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        revision: revision
      }
    end)
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
        nights = Date.diff(group.departure_on, group.arrival_on)
        lodging_total_cents = Enum.sum(Enum.map(rooms, &room_lodging_cents(&1, nights)))

        {:ok,
         %{
           group: group,
           rooms: rooms,
           totals: %{
             lodging_total_cents: lodging_total_cents,
             deposit_due_cents: group.deposit_due_cents,
             deposit_paid_cents: paid_cents(sums),
             outstanding_deposit_cents:
               if Group.active?(group) do
                 max(group.deposit_due_cents - paid_cents(sums), 0)
               else
                 0
               end
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
    sums.payment - sums.refund - sums.retention
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

  defp in_transaction(group_id, expected_revision, apply) do
    Repo.transaction(fn ->
      group = Repo.get_by(Group, group_id: group_id) || Repo.rollback({:error, :group_not_found})

      case check_revision(group, expected_revision) do
        :ok -> nil
        {:stale, expected} -> Repo.rollback({:stale_revision, expected, group.revision})
      end

      Group.active?(group) or Repo.rollback({:error, :group_not_active})
      apply.(group)
    end)
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, {:error, reason}} ->
        {:error, reason}

      {:error, {:stale_revision, expected, actual}} ->
        {:error, {:stale_revision, expected, actual}}
    end
  end

  defp check_revision(_group, nil), do: :ok

  defp check_revision(group, expected_revision) do
    if expected_revision == group.revision, do: :ok, else: {:stale, expected_revision}
  end

  defp bump_revision!(group) do
    {1, _} =
      from(g in Group, where: g.id == ^group.id)
      |> Repo.update_all(inc: [revision: 1])

    group.revision + 1
  end

  defp refundable?(%Group{} = group, occurred_on) do
    group.rate_plan == "flexible" and
      Date.diff(group.arrival_on, occurred_on) >= @refundable_days_before_arrival
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

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
