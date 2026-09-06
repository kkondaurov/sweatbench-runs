defmodule GroupStay.Groups do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Money
  alias GroupStay.Repo
  alias GroupStay.Groups.Group

  def get_by_group_id(group_id) when is_binary(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> case do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_by_group_id(_), do: nil

  def exists?(group_id) when is_binary(group_id) do
    Repo.exists?(from g in Group, where: g.group_id == ^group_id)
  end

  def exists?(_), do: false

  def nights(%Date{} = arrival_on, %Date{} = departure_on) do
    Date.diff(departure_on, arrival_on)
  end

  def lodging_total_cents(rooms, nights) when nights > 0 do
    Enum.reduce(rooms, 0, fn room, acc ->
      acc + room.nightly_rate_cents * nights
    end)
  end

  def deposit_due_cents(rooms, nights, rate_plan) when nights > 0 do
    Enum.reduce(rooms, 0, fn room, acc ->
      lodging = room.nightly_rate_cents * nights
      acc + room_deposit_cents(lodging, rate_plan)
    end)
  end

  def outstanding_deposit_cents(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%Group{} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  def serialize(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      status: group.status,
      rooms: Enum.map(group.rooms, &serialize_room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  def ledger do
    %{
      cash_held_cents: sum_where(:deposit_paid_cents, "active"),
      cash_refunded_cents: sum_field(:refunded_cents),
      cash_retained_cents: sum_field(:retained_cents)
    }
  end

  defp sum_where(field, status) do
    from(g in Group, where: g.status == ^status, select: coalesce(sum(field(g, ^field)), 0))
    |> Repo.one()
  end

  defp sum_field(field) do
    from(g in Group, select: coalesce(sum(field(g, ^field)), 0))
    |> Repo.one()
  end

  defp room_deposit_cents(lodging_cents, "flexible"), do: Money.percent(lodging_cents, 20)
  defp room_deposit_cents(lodging_cents, "advance_purchase"), do: lodging_cents

  defp serialize_room(room) do
    %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
  end
end
