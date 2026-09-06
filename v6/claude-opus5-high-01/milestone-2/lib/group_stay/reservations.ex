defmodule GroupStay.Reservations do
  @moduledoc """
  Group reservations: the rooms they hold, the deposit they require, and the cash
  and hotel credit recorded against that deposit.

  Every change addressed to an existing group advances its `revision` exactly once.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias GroupStay.Credit
  alias GroupStay.Policy
  alias GroupStay.Pricing
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Room

  @credit_bonus_percent 10

  @doc "Fetches a group by its partner identifier, with rooms in their original order."
  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> load_rooms()
  end

  defp load_rooms(nil), do: nil
  defp load_rooms(%Group{} = group), do: Repo.preload(group, :rooms)

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
          position: index
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
        credit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0
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

  @doc "Applies cash to a group's outstanding deposit."
  def record_cash_payment(%Group{} = group, amount_cents) do
    update_group(group, %{cash_paid_cents: group.cash_paid_cents + amount_cents})
  end

  @doc """
  Redeems the guest's hotel credit into a group's outstanding deposit.

  Expiry is evaluated as of `occurred_on`. Returns `{:error, "insufficient_credit"}`
  when the guest does not hold enough unexpired credit.
  """
  def apply_hotel_credit(%Group{} = group, amount_cents, occurred_on) do
    with :ok <- Credit.redeem(group, amount_cents, occurred_on) do
      {:ok, _group} =
        update_group(group, %{credit_paid_cents: group.credit_paid_cents + amount_cents})
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
  Cancels a group and settles the cash and credit it holds.

  `refund_method` is `"cash"` or `"hotel_credit"`; the caller has already refused
  hotel credit for a non-refundable cancellation. Returns the updated group and a
  settlement map of `refunded_cents`, `retained_cents`, `converted_cents`, and
  `credit_issued_cents`.
  """
  def cancel(%Group{} = group, occurred_on, refund_method, operation_id) do
    refundable? = Group.refundable?(group, occurred_on)
    settlement = settle(refundable?, refund_method, group.cash_paid_cents)

    # A refundable cancellation hands redeemed credit back to its own lots; a
    # non-refundable one consumes it along with the cash.
    if refundable? do
      :ok = Credit.restore(group)
    end

    if settlement.credit_issued_cents > 0 do
      {:ok, _lot} =
        Credit.issue_lot(
          group.guest_id,
          operation_id,
          settlement.credit_issued_cents,
          occurred_on
        )
    end

    {:ok, group} =
      update_group(group, %{
        status: "cancelled",
        cash_refunded_cents: group.cash_refunded_cents + settlement.refunded_cents,
        cash_retained_cents: group.cash_retained_cents + settlement.retained_cents,
        cash_converted_to_credit_cents:
          group.cash_converted_to_credit_cents + settlement.converted_cents
      })

    {:ok, group, settlement}
  end

  defp settle(false, _refund_method, cash_cents) do
    %{
      refunded_cents: 0,
      retained_cents: cash_cents,
      converted_cents: 0,
      credit_issued_cents: 0
    }
  end

  defp settle(true, "hotel_credit", cash_cents) do
    # The cash is neither refunded nor retained: it leaves as credit worth 110%.
    %{
      refunded_cents: 0,
      retained_cents: 0,
      converted_cents: cash_cents,
      credit_issued_cents: cash_cents + Pricing.percent_of(cash_cents, @credit_bonus_percent)
    }
  end

  defp settle(true, "cash", cash_cents) do
    %{
      refunded_cents: cash_cents,
      retained_cents: 0,
      converted_cents: 0,
      credit_issued_cents: 0
    }
  end

  defp update_group(%Group{} = group, attrs) do
    group
    |> Group.changeset(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update()
    |> case do
      {:ok, group} -> {:ok, load_rooms(group)}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
