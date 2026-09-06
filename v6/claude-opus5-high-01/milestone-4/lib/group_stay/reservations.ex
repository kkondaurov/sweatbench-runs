defmodule GroupStay.Reservations do
  @moduledoc """
  Group reservations: the rooms they hold, the deposit those rooms require, and
  the cash and hotel credit recorded against that deposit.

  Deposits are owed and funded room by room, so cancelling part of a room block
  settles only the allocations of the rooms it names. Every change addressed to
  an existing group advances its `revision` exactly once.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias GroupStay.Credit
  alias GroupStay.Funding
  alias GroupStay.Policy
  alias GroupStay.Pricing
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Room

  @doc """
  Fetches a group by its partner identifier.

  Rooms come back in their original order, each carrying the funding still
  attributed to it.
  """
  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> load_rooms()
  end

  defp load_rooms(nil), do: nil

  defp load_rooms(%Group{} = group) do
    group
    |> Repo.preload(:rooms, force: true)
    |> Funding.with_room_funding()
  end

  @doc "The group's rooms that have not been cancelled, in their original order."
  defdelegate active_rooms(group), to: GroupStay.Funding

  @doc "True when a group with this partner identifier already exists."
  def group_exists?(group_id) when is_binary(group_id) do
    Repo.exists?(from g in Group, where: g.group_id == ^group_id)
  end

  @doc """
  Opens a group for the given rooms.

  `rooms` is a list of `{room_id, nightly_rate_cents}` tuples in partner order. The
  caller is responsible for validating the stay, the rate plan, and the rooms.
  """
  def open_group(attrs, rooms) do
    nights = Pricing.nights(attrs.arrival_on, attrs.departure_on)

    priced_rooms =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {{room_id, nightly_rate_cents}, index} ->
        lodging_cents = Pricing.lodging_cents(nightly_rate_cents, nights)

        %{
          room_id: room_id,
          nightly_rate_cents: nightly_rate_cents,
          lodging_cents: lodging_cents,
          deposit_cents: Pricing.room_deposit_cents(attrs.rate_plan, lodging_cents),
          position: index,
          status: "active"
        }
      end)

    group_attrs =
      attrs
      |> Map.merge(%{
        status: "active",
        revision: 1,
        # Fixed at open: a later reschedule never moves the group to a newer policy.
        policy_version: Policy.version_for(attrs.rate_plan, attrs.booked_on),
        lodging_total_cents: Enum.sum(Enum.map(priced_rooms, & &1.lodging_cents)),
        deposit_due_cents: Enum.sum(Enum.map(priced_rooms, & &1.deposit_cents)),
        cash_paid_cents: 0,
        credit_paid_cents: 0
      })

    Multi.new()
    |> Multi.insert(:group, Group.changeset(%Group{}, group_attrs))
    |> Multi.run(:rooms, fn repo, %{group: group} ->
      Enum.reduce_while(priced_rooms, {:ok, []}, fn room_attrs, {:ok, acc} ->
        %Room{group_ref: group.id}
        |> Room.changeset(room_attrs)
        |> repo.insert()
        |> case do
          {:ok, room} -> {:cont, {:ok, [room | acc]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{group: group}} -> {:ok, load_rooms(group)}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc "Applies one payment's cash to the group's active room deposits."
  def record_cash_payment(%Group{} = group, amount_cents, operation_id) do
    :ok = Funding.allocate_cash(group, operation_id, amount_cents)

    update_group(group, %{})
  end

  @doc """
  Redeems the guest's hotel credit into the group's active room deposits.

  Expiry is evaluated as of `occurred_on`. Returns `{:error, "insufficient_credit"}`
  when the guest does not hold enough unexpired credit.
  """
  def apply_hotel_credit(%Group{} = group, amount_cents, occurred_on, operation_id) do
    with {:ok, slices} <- Credit.reserve(group.guest_id, amount_cents, occurred_on) do
      :ok = Funding.allocate_credit(group, operation_id, slices)

      update_group(group, %{})
    end
  end

  @doc "Moves a stay to a new arrival date, keeping its length."
  def reschedule(%Group{} = group, new_arrival_on) do
    shift = Date.diff(new_arrival_on, group.arrival_on)

    update_group(group, %{
      arrival_on: new_arrival_on,
      departure_on: Date.add(group.departure_on, shift)
    })
  end

  @doc """
  Cancels `rooms` and settles the cash and credit allocated to them.

  `refund_method` is `"cash"` or `"hotel_credit"`; the caller has already refused
  hotel credit for a non-refundable cancellation. The credit bonus is taken once
  on the rooms' combined cash. The group is cancelled when no active room is
  left. Returns the updated group and a settlement map of `refunded_cents`,
  `retained_cents`, `converted_cents`, and `credit_issued_cents`.
  """
  def cancel_rooms(%Group{} = group, rooms, occurred_on, refund_method, operation_id) do
    settlement =
      Funding.settle_rooms(group, rooms, %{
        refundable?: Group.refundable?(group, occurred_on),
        refund_method: refund_method,
        operation_id: operation_id,
        occurred_on: occurred_on
      })

    for room <- rooms do
      {:ok, _room} = room |> Room.changeset(%{status: "cancelled"}) |> Repo.update()
    end

    {:ok, group} = update_group(group, status_after_cancelling(group))

    {:ok, group, settlement}
  end

  defp status_after_cancelling(group) do
    case Funding.active_rooms(group) do
      [] -> %{status: "cancelled"}
      _rooms -> %{}
    end
  end

  @doc """
  Takes back cash a provider reported as overstated.

  The cash leaves the rooms it funded in reverse fill order, so the group's
  outstanding deposit reopens by the amount removed.
  """
  def reduce_cash_payment(%Group{} = group, payment_operation_id, amount_cents) do
    :ok = Funding.reduce_cash(payment_operation_id, amount_cents)

    update_group(group, %{})
  end

  @doc """
  Reverses every remaining disposition of one payment's cash.

  Returns the updated group and the amount charged back.
  """
  def charge_back_payment(%Group{} = group, payment_operation_id) do
    charged_back_cents = Funding.charge_back(payment_operation_id)

    {:ok, group} = update_group(group, %{})

    {:ok, group, charged_back_cents}
  end

  # Every applied change addressed to a group advances its revision exactly once.
  # While the group is active its totals follow its active rooms; once it is
  # cancelled they stand as the record of what it held.
  defp update_group(%Group{} = group, attrs) do
    attrs =
      case Map.get(attrs, :status, group.status) do
        "active" -> Map.merge(Funding.group_totals(group), attrs)
        _cancelled -> attrs
      end

    group
    |> Group.changeset(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update()
    |> case do
      {:ok, group} -> {:ok, load_rooms(group)}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
