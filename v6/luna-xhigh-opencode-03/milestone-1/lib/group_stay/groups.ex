defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.{Group, GroupRoom, Repo}

  def get(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, rooms: from(room in GroupRoom, order_by: room.position))}
    end
  end

  def get(_group_id), do: {:error, :group_not_found}

  def ledger_totals do
    Repo.all(
      from group in Group,
        select:
          {group.status, group.deposit_paid_cents, group.refunded_cents, group.retained_cents}
    )
    |> Enum.reduce(
      %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0},
      fn {status, paid, refunded, retained}, totals ->
        %{
          cash_held_cents:
            if(status == "active",
              do: totals.cash_held_cents + paid,
              else: totals.cash_held_cents
            ),
          cash_refunded_cents: totals.cash_refunded_cents + refunded,
          cash_retained_cents: totals.cash_retained_cents + retained
        }
      end
    )
  end

  def serialize(%Group{} = group) do
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
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp outstanding_deposit(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding_deposit(%Group{}), do: 0
end
