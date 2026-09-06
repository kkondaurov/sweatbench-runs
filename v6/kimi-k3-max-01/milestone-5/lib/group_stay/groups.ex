defmodule GroupStay.Groups do
  @moduledoc """
  The groups context: group reservations, their rooms, the funding allocated
  to room deposits, and the deposit state machine (open, funded, rescheduled,
  settled, cancelled).

  Cash and hotel credit fund active room deposits in the rooms' original
  order, filling one room's deposit before moving to the next. Group totals
  are sums of the active rooms and are recomputed (together with the
  revision increment) by `refresh_group!/2` after every state change.
  """

  import Ecto.Query

  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  # Flexible groups booked on or after this date use the 30-day cancellation
  # window; earlier bookings keep the 14-day window.
  @flex_30_cutover_on ~D[2027-01-01]

  @doc """
  Fetches a group by its partner-supplied identifier, with rooms in their
  original order. Returns `nil` when no such group exists.
  """
  def get_group(group_id) when is_binary(group_id) do
    Group
    |> where(group_id: ^group_id)
    |> preload(:rooms)
    |> Repo.one()
  end

  def get_group(_group_id), do: nil

  @doc """
  Fetches a group by its internal identifier, with rooms in their original
  order.
  """
  def get_group_by_id!(id) do
    Group
    |> Repo.get!(id)
    |> Repo.preload(:rooms)
  end

  @doc """
  The group's active rooms in their original order.
  """
  def active_rooms(%Group{} = group) do
    Enum.filter(group.rooms, &(&1.status == "active"))
  end

  @doc """
  The number of active rooms, read from the database.
  """
  def active_room_count(%Group{} = group) do
    Room
    |> where(group_id: ^group.id, status: "active")
    |> Repo.aggregate(:count)
  end

  @doc """
  The number of nights in a stay.
  """
  def nights(%Group{} = group), do: Date.diff(group.departure_on, group.arrival_on)

  @doc """
  The deposit still owed by the group. Cancellation settles the requirement,
  so a cancelled group has no outstanding deposit.
  """
  def outstanding_deposit_cents(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%Group{} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  @doc """
  The cancellation policy version that applies to a group opened with the
  given rate plan and booking date. The version is fixed when the group is
  opened; rescheduling never moves a group to a newer policy.
  """
  def policy_version("advance_purchase", %Date{}), do: "advance-nonrefundable"

  def policy_version("flexible", %Date{} = booked_on) do
    if Date.compare(booked_on, @flex_30_cutover_on) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  The number of calendar days before arrival that a cancellation must occur
  to be refundable under the given policy version.
  """
  def cancellation_window_days("flex-14"), do: 14
  def cancellation_window_days("flex-30"), do: 30

  @doc """
  The last date on which cancellation is refundable for the group: the
  arrival date minus its cancellation window. `nil` for advance purchase.
  """
  def refundable_until(%Group{policy_version: "advance-nonrefundable"}), do: nil

  def refundable_until(%Group{} = group) do
    Date.shift(group.arrival_on, day: -cancellation_window_days(group.policy_version))
  end

  @doc """
  Whether cancelling the group on the given date is refundable. Cancellation
  exactly on `refundable_until` is refundable.
  """
  def refundable?(%Group{} = group, %Date{} = on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(on, until) != :gt
    end
  end

  @doc """
  Computes the lodging total and the deposit due for a stay.

  The lodging total is the sum of each room's nightly rate multiplied by the
  number of nights. Flexible rooms require 20% of their lodging as deposit;
  the percentage is calculated per room and rounded to the nearest cent with
  an exact half-cent rounding upward. Advance-purchase rooms require their
  full lodging amount.
  """
  def totals(rate_plan, rooms, nights) do
    lodging_total = Enum.sum(for room <- rooms, do: room.nightly_rate_cents * nights)

    deposit_due =
      Enum.sum(
        for room <- rooms, do: room_deposit_cents(rate_plan, room.nightly_rate_cents * nights)
      )

    %{lodging_total_cents: lodging_total, deposit_due_cents: deposit_due}
  end

  @doc """
  The deposit due for one room's lodging amount under a rate plan.
  """
  def room_deposit_cents("flexible", lodging_cents), do: round_half_up(lodging_cents * 20, 100)
  def room_deposit_cents("advance_purchase", lodging_cents), do: lodging_cents

  @doc """
  Rounds `numerator / denominator` to the nearest integer; an exact half
  rounds upward. Both arguments must be non-negative integers.
  """
  def round_half_up(numerator, denominator)
      when is_integer(numerator) and numerator >= 0 and is_integer(denominator) and
             denominator > 0 do
    div(2 * numerator + denominator, 2 * denominator)
  end

  ## Funding allocations

  @doc """
  Allocates `amount_cents` of funding to the group's active rooms in their
  original order, filling one room's deposit before moving to the next.

  `opts` carries the funding's provenance: `payment_operation_id` for cash,
  `credit_lot_id` for hotel credit, and `transferred` for funding that has
  participated in a deposit transfer. The caller must have verified the
  amount fits the group's outstanding deposit.
  """
  def allocate_funding!(%Group{} = group, kind, amount_cents, opts \\ [])
      when kind in ["cash", "credit"] and amount_cents > 0 do
    rooms =
      Room
      |> where(group_id: ^group.id, status: "active")
      |> order_by(:position)
      |> Repo.all()

    do_allocate!(group, rooms, kind, amount_cents, opts)
  end

  defp do_allocate!(_group, _rooms, _kind, 0, _opts), do: :ok

  defp do_allocate!(%Group{}, [], _kind, amount_cents, _opts) when amount_cents > 0 do
    raise "funding exceeds the group's active room capacity"
  end

  defp do_allocate!(%Group{} = group, [room | rooms], kind, amount_cents, opts) do
    capacity = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
    take = min(capacity, amount_cents)

    if take > 0 do
      %Allocation{}
      |> Allocation.changeset(%{
        room_id: room.id,
        group_id: group.id,
        kind: kind,
        amount_cents: take,
        payment_operation_id: Keyword.get(opts, :payment_operation_id),
        credit_lot_id: Keyword.get(opts, :credit_lot_id),
        transferred: Keyword.get(opts, :transferred, false)
      })
      |> Repo.insert!()

      {cash_paid, credit_paid} =
        case kind do
          "cash" -> {room.cash_paid_cents + take, room.credit_paid_cents}
          "credit" -> {room.cash_paid_cents, room.credit_paid_cents + take}
        end

      {:ok, _room} =
        room
        |> Room.changeset(%{cash_paid_cents: cash_paid, credit_paid_cents: credit_paid})
        |> Repo.update()
    end

    do_allocate!(group, rooms, kind, amount_cents - take, opts)
  end

  @doc """
  The group's held funding allocations, ordered by creation (`:asc`, the
  default) or most recently created first (`:desc`), with rooms preloaded.
  """
  def held_allocations(%Group{} = group, order \\ :asc) when order in [:asc, :desc] do
    Allocation
    |> where(group_id: ^group.id)
    |> order_by([allocation], [{^order, allocation.id}])
    |> preload(:room)
    |> Repo.all()
  end

  @doc """
  The held cash allocations of one payment across all groups, most recently
  created first, with rooms preloaded.
  """
  def payment_cash_allocations(payment_operation_id) do
    Allocation
    |> where(kind: "cash", payment_operation_id: ^payment_operation_id)
    |> order_by(desc: :id)
    |> preload(:room)
    |> Repo.all()
  end

  @doc """
  The funding currently held on the group's active rooms.
  """
  def held_funding_cents(%Group{} = group) do
    Allocation
    |> where(group_id: ^group.id)
    |> select([allocation], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  @doc """
  Draws up to `amount_cents` from the given allocations, which must be
  ordered most recently created first with rooms preloaded. Trims or deletes
  the allocation rows and updates the rooms' paid totals. Returns the drawn
  units in draw order, each keeping its provenance.
  """
  def draw_allocations!(allocations, amount_cents) when amount_cents > 0 do
    {units, _left, _room_cache} =
      Enum.reduce_while(allocations, {[], amount_cents, %{}}, fn allocation,
                                                                 {units, left, room_cache} ->
        if left == 0 do
          {:halt, {units, 0, room_cache}}
        else
          take = min(allocation.amount_cents, left)

          if take == allocation.amount_cents do
            Repo.delete!(allocation)
          else
            {:ok, _allocation} =
              allocation
              |> Allocation.changeset(%{amount_cents: allocation.amount_cents - take})
              |> Repo.update()
          end

          room = allocation.room

          {cash_paid, credit_paid} =
            Map.get(room_cache, room.id, {room.cash_paid_cents, room.credit_paid_cents})

          {cash_paid, credit_paid} =
            case allocation.kind do
              "cash" -> {cash_paid - take, credit_paid}
              "credit" -> {cash_paid, credit_paid - take}
            end

          {:ok, _room} =
            room
            |> Room.changeset(%{cash_paid_cents: cash_paid, credit_paid_cents: credit_paid})
            |> Repo.update()

          unit = %{
            group_id: allocation.group_id,
            kind: allocation.kind,
            amount_cents: take,
            payment_operation_id: allocation.payment_operation_id,
            credit_lot_id: allocation.credit_lot_id,
            transferred: allocation.transferred
          }

          room_cache = Map.put(room_cache, room.id, {cash_paid, credit_paid})

          {:cont, {[unit | units], left - take, room_cache}}
        end
      end)

    Enum.reverse(units)
  end

  @doc """
  Marks the given rooms cancelled and deletes their allocations; their
  deposit requirements cease to be due and their funding is settled.
  """
  def settle_rooms!(rooms) do
    for room <- rooms do
      Allocation
      |> where(room_id: ^room.id)
      |> Repo.delete_all()

      {:ok, _room} =
        room
        |> Room.changeset(%{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
        |> Repo.update()
    end

    :ok
  end

  @doc """
  Recomputes the group's totals from its active rooms, persists them
  together with any extra attributes, and increments the revision exactly
  once. Every applied operation that changes a group ends here.
  """
  def refresh_group!(%Group{} = group, extra_attrs \\ %{}) do
    group = Repo.preload(group, :rooms, force: true)
    active = active_rooms(group)
    nights = nights(group)

    attrs =
      Map.merge(
        %{
          lodging_total_cents: Enum.sum(for room <- active, do: room.nightly_rate_cents * nights),
          deposit_due_cents: Enum.sum(for room <- active, do: room.deposit_due_cents),
          cash_paid_cents: Enum.sum(for room <- active, do: room.cash_paid_cents),
          credit_paid_cents: Enum.sum(for room <- active, do: room.credit_paid_cents)
        },
        extra_attrs
      )

    attrs = Map.put(attrs, :deposit_paid_cents, attrs.cash_paid_cents + attrs.credit_paid_cents)

    group
    |> Group.update_changeset(attrs)
    |> Repo.update!()
  end

  @doc """
  The JSON representation of a group as returned by the read endpoint. Group
  totals describe active rooms only; every room exposes its own deposit
  state.
  """
  def group_payload(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      policy_version: group.policy_version,
      refundable_until: refundable_until_iso8601(group),
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  @doc """
  `refundable_until` formatted for JSON responses; `nil` for advance
  purchase.
  """
  def refundable_until_iso8601(%Group{} = group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end
end
