defmodule GroupStay.Groups do
  @moduledoc """
  The group reservation domain: reading groups and the finance totals derived
  from them.

  GroupStay owns the rooms represented by each group reservation, the deposit
  required for those rooms, the cash applied to that deposit, and the
  cancellation settlements that feed the finance totals.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @doc """
  Returns whether a group with the given partner identifier exists.
  """
  def group_exists?(group_id) when is_binary(group_id) do
    Repo.exists?(from g in Group, where: g.group_id == ^group_id)
  end

  @doc """
  Fetches a group by its partner identifier.
  """
  def fetch_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :error
      %Group{} = group -> {:ok, group}
    end
  end

  @doc """
  Builds the JSON representation of a group, including its rooms in their
  original order and its deposit totals.
  """
  def group_data(%Group{} = group) do
    rooms =
      Repo.all(
        from r in Room,
          where: r.group_id == ^group.id,
          order_by: r.position
      )

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "rooms" => Enum.map(rooms, &room_data/1),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit_cents(group)
    }
  end

  defp room_data(%Room{} = room) do
    %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
  end

  @doc """
  The deposit still to be paid on a group. Once a group is cancelled its
  unpaid deposit is simply no longer due.
  """
  def outstanding_deposit_cents(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%Group{} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  @doc """
  The finance totals over all groups: cash currently applied to active
  reservations, and cash moved out of active reservations by cancellations.
  Unpaid deposit requirements are not cash and never appear here.
  """
  def ledger_totals do
    %{
      "cash_held_cents" => cash_held_cents(),
      "cash_refunded_cents" => sum_groups(:refunded_cents),
      "cash_retained_cents" => sum_groups(:retained_cents)
    }
  end

  defp cash_held_cents do
    Repo.one(
      from g in Group,
        where: g.status == "active",
        select: sum(g.deposit_paid_cents)
    )
    |> Kernel.||(0)
  end

  defp sum_groups(field) do
    Repo.one(
      from g in Group,
        select: sum(field(g, ^field))
    )
    |> Kernel.||(0)
  end
end
