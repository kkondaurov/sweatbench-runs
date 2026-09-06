defmodule GroupStay.Groups do
  @moduledoc """
  Persistence and presentation helpers for group reservations.
  """

  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  def get(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, rooms: from(room in Room, order_by: room.position))
    end
  end

  def get(_group_id), do: nil

  def present(group) do
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

  def outstanding_deposit(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  def outstanding_deposit(%Group{}), do: 0

  def ledger do
    %{
      cash_held_cents: sum(:deposit_paid_cents, status: "active"),
      cash_refunded_cents: sum(:cancelled_refunded_cents),
      cash_retained_cents: sum(:cancelled_retained_cents)
    }
  end

  defp sum(field, filters \\ []) do
    query = from(group in Group, select: coalesce(sum(field(group, ^field)), 0))

    query =
      case Keyword.fetch(filters, :status) do
        {:ok, status} -> from(group in query, where: group.status == ^status)
        :error -> query
      end

    Repo.one(query)
  end
end
