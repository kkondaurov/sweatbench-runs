defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.{Ledger, Repo}

  def get(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :not_found
      group -> {:ok, serialize(group)}
    end
  end

  def ledger_totals do
    cash_held =
      Repo.one(
        from group in Group,
          where: group.status == "active",
          select: coalesce(sum(group.deposit_paid_cents), 0)
      ) || 0

    ledger = Repo.get(Ledger, 1)

    %{
      cash_held_cents: cash_held,
      cash_refunded_cents: (ledger && ledger.cash_refunded_cents) || 0,
      cash_retained_cents: (ledger && ledger.cash_retained_cents) || 0
    }
  end

  defp serialize(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: [asc: room.position],
          select: %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
      )

    outstanding =
      if group.status == "active" do
        max(group.deposit_due_cents - group.deposit_paid_cents, 0)
      else
        0
      end

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding
    }
  end
end
