defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Groups.{CreditAllocation, CreditLot, Group, Room}
  alias GroupStay.Repo

  @policy_cutover ~D[2027-01-01]

  @doc "Returns a group in the partner API representation, or nil when it does not exist."
  def get(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> serialize_group(group)
    end
  end

  @doc "Returns the current finance totals in cents."
  def ledger(as_of \\ Date.utc_today()) do
    %{
      cash_held_cents: sum_where("active", :cash_paid_cents),
      cash_refunded_cents: sum_where("cancelled", :cash_refunded_cents),
      cash_retained_cents: sum_where("cancelled", :cash_retained_cents),
      cash_converted_to_credit_cents: sum_where("cancelled", :cash_converted_to_credit_cents),
      credit_liability_cents: credit_liability(as_of)
    }
  end

  @doc "Returns the credit currently available to a guest as of a date."
  def credit_for_guest(guest_id, as_of \\ Date.utc_today()) do
    lots =
      from(l in CreditLot,
        where:
          l.guest_id == ^guest_id and l.remaining_cents > 0 and
            l.expires_on >= ^as_of,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id],
        select: %{
          source_operation_id: l.source_operation_id,
          remaining_cents: l.remaining_cents,
          expires_on: l.expires_on
        }
      )
      |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &serialize_credit_lot/1)
    }
  end

  @doc "Returns the policy fixed when the group was opened."
  def policy_version(%Group{policy_version: version})
      when version in ["flex-14", "flex-30", "advance-nonrefundable"],
      do: version

  def policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version_for(rate_plan, booked_on)

  def policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  def refundable_until(%Group{} = group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  def refundable?(%Group{} = group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) in [:lt, :eq]
    end
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
      policy_version: policy_version(group),
      refundable_until: serialize_date(refundable_until(group)),
      rooms: rooms_for(group.group_id),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: cash_paid_cents(group),
      credit_paid_cents: group.credit_paid_cents || 0,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp serialize_credit_lot(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end

  defp serialize_date(nil), do: nil
  defp serialize_date(date), do: Date.to_iso8601(date)

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from a in CreditAllocation,
          join: g in Group,
          on: g.group_id == a.group_id,
          where: g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + applied
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

  defp cash_paid_cents(%Group{
         cash_paid_cents: cash,
         deposit_paid_cents: deposit,
         credit_paid_cents: credit
       }) do
    cond do
      is_integer(cash) and cash > 0 -> cash
      is_integer(credit) and credit > 0 -> 0
      is_integer(deposit) -> deposit
      true -> 0
    end
  end

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
