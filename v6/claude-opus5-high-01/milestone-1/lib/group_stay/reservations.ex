defmodule GroupStay.Reservations do
  @moduledoc """
  Group reservations: the rooms they hold, the deposit they require, and the cash
  recorded against that deposit.

  Every change addressed to an existing group advances its `revision` exactly once.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias GroupStay.Pricing
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Room

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
        lodging_total_cents: Enum.sum(Enum.map(priced_rooms, & &1.lodging_cents)),
        deposit_due_cents: Enum.sum(Enum.map(priced_rooms, & &1.deposit_cents)),
        deposit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0
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
    update_group(group, %{deposit_paid_cents: group.deposit_paid_cents + amount_cents})
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
  Cancels a group and settles the cash it holds.

  Returns the updated group along with the refunded and retained amounts.
  """
  def cancel(%Group{} = group, occurred_on) do
    {refunded, retained} =
      if refundable?(group, occurred_on) do
        {group.deposit_paid_cents, 0}
      else
        {0, group.deposit_paid_cents}
      end

    with {:ok, group} <-
           update_group(group, %{
             status: "cancelled",
             cash_refunded_cents: group.cash_refunded_cents + refunded,
             cash_retained_cents: group.cash_retained_cents + retained
           }) do
      {:ok, group, refunded, retained}
    end
  end

  @doc """
  True when cancelling on `occurred_on` refunds the cash already paid.

  Flexible stays are refundable up to 14 calendar days before arrival;
  advance-purchase stays never are.
  """
  def refundable?(%Group{rate_plan: "flexible"} = group, occurred_on),
    do: Date.diff(group.arrival_on, occurred_on) >= 14

  def refundable?(%Group{}, _occurred_on), do: false

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
