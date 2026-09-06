defmodule GroupStay.Groups do
  @moduledoc """
  Read-side access to group reservations and the deposit ledger.
  """

  import Ecto.Query

  alias GroupStay.Groups.{CashPayment, Group, Room}
  alias GroupStay.Repo

  @doc """
  Fetches a group by its partner identifier, with rooms in their original
  order. Returns `nil` when the group does not exist.
  """
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        nil

      group ->
        Repo.preload(group, rooms: from(r in Room, order_by: [asc: r.position]))
    end
  end

  @doc """
  Builds the JSON representation of a group for the partner API.
  """
  def group_view(%Group{} = group) do
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
      "rooms" => Enum.map(group.rooms, &room_view/1),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit_cents(group)
    }
  end

  defp room_view(%Room{} = room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents
    }
  end

  @doc """
  Unpaid deposit is only due while the group is active; cancellation drops
  the remaining requirement.
  """
  def outstanding_deposit_cents(%Group{} = group) do
    if group.status == "active" do
      group.deposit_due_cents - group.deposit_paid_cents
    else
      0
    end
  end

  @doc """
  Finance totals across all groups.

  Cash held is the cash currently applied to active reservations;
  cancellation moves each group's cash to refunded or retained. Unpaid
  deposit requirements are not cash and never appear here.
  """
  def ledger do
    cash_held =
      Repo.one(
        from p in CashPayment,
          join: g in assoc(p, :group),
          where: g.status == "active",
          select: coalesce(sum(p.amount_cents), 0)
      )

    cash_refunded = Repo.one(from g in Group, select: coalesce(sum(g.refunded_cents), 0))
    cash_retained = Repo.one(from g in Group, select: coalesce(sum(g.retained_cents), 0))

    %{
      "cash_held_cents" => cash_held,
      "cash_refunded_cents" => cash_refunded,
      "cash_retained_cents" => cash_retained
    }
  end
end
