defmodule GroupStay.Groups do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Money
  alias GroupStay.Repo
  alias GroupStay.Groups.Group

  @flex_30_starts_on ~D[2027-01-01]

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

  def policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_starts_on) == :lt do
      "flex-14"
    else
      "flex-30"
    end
  end

  def policy_version(%Group{policy_version: version} = group) when version in [nil, ""] do
    policy_version_for(group.rate_plan, group.booked_on)
  end

  def policy_version(%Group{policy_version: version}), do: version

  def refundable_until(%Group{} = group) do
    case cancellation_window_days(policy_version(group)) do
      nil -> nil
      days -> Date.add(group.arrival_on, -days)
    end
  end

  def refundable?(%Group{} = group, %Date{} = occurred_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(occurred_on, until) != :gt
    end
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
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms: Enum.map(group.rooms, &serialize_room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents || 0,
      credit_paid_cents: group.credit_paid_cents || 0,
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  def ledger(as_of \\ nil) do
    as_of = Credit.as_of(as_of)

    %{
      cash_held_cents: sum_where(:cash_paid_cents, "active"),
      cash_refunded_cents: sum_field(:refunded_cents),
      cash_retained_cents: sum_field(:retained_cents),
      cash_converted_to_credit_cents: sum_field(:cash_converted_to_credit_cents),
      credit_liability_cents: Credit.liability_cents(as_of)
    }
  end

  defp cancellation_window_days("flex-14"), do: 14
  defp cancellation_window_days("flex-30"), do: 30
  defp cancellation_window_days("advance-nonrefundable"), do: nil

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
