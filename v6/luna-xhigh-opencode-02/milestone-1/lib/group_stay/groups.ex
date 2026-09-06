defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @doc "Returns a group in the partner API representation, or nil when it does not exist."
  def get(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> serialize_group(group)
    end
  end

  @doc "Returns the current finance totals in cents."
  def ledger do
    %{
      cash_held_cents: sum_where("active", :deposit_paid_cents),
      cash_refunded_cents: sum_where("cancelled", :cash_refunded_cents),
      cash_retained_cents: sum_where("cancelled", :cash_retained_cents)
    }
  end

  defp sum_where(status, field) do
    Repo.one(
      from g in Group,
        where: g.status == ^status,
        select: coalesce(sum(field(g, ^field)), 0)
    )
  end

  def serialize_group(%Group{} = group) do
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
      rooms: rooms_for(group.group_id),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp rooms_for(group_id) do
    from(r in Room,
      where: r.group_id == ^group_id,
      order_by: r.position,
      select: %{room_id: r.room_id, nightly_rate_cents: r.nightly_rate_cents}
    )
    |> Repo.all()
  end

  defp outstanding_deposit(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp outstanding_deposit(%Group{}), do: 0

  def insert_group(attrs, rooms) do
    group = %Group{}
    changeset = Group.changeset(group, attrs)

    case Repo.insert(changeset) do
      {:ok, group} ->
        Repo.insert_all(Room, Enum.map(rooms, &Map.put(&1, :group_id, group.group_id)))
        {:ok, group}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
