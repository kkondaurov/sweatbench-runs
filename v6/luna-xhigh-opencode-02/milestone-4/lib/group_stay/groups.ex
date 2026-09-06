defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Groups.{CashAllocation, CreditAllocation, CreditLot, Group, Room}
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
      cash_held_cents: cash_sum(:held_cents),
      cash_refunded_cents: cash_sum(:refunded_cents),
      cash_retained_cents: cash_sum(:retained_cents),
      cash_converted_to_credit_cents: cash_sum(:converted_to_credit_cents),
      cash_reduced_cents: cash_sum(:reduced_cents),
      cash_charged_back_cents: cash_sum(:charged_back_cents),
      credit_liability_cents: credit_liability(as_of),
      credit_shortfall_cents: credit_shortfall()
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

  @doc "Returns the fixed cancellation policy for a group."
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

  @doc "Returns room records with their currently held funding."
  def rooms_with_funding(group_id) do
    rooms =
      from(r in Room, where: r.group_id == ^group_id, order_by: [asc: r.position, asc: r.id])
      |> Repo.all()

    cash =
      from(a in CashAllocation,
        where: a.group_id == ^group_id,
        group_by: a.room_id,
        select: {a.room_id, coalesce(sum(a.held_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    credit =
      from(a in CreditAllocation,
        where: a.group_id == ^group_id,
        group_by: a.room_id,
        select: {a.room_id, coalesce(sum(a.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(rooms, fn room ->
      Map.merge(
        room,
        %{
          cash_paid_cents: Map.get(cash, room.id, 0),
          credit_paid_cents: Map.get(credit, room.id, 0)
        }
      )
    end)
  end

  @doc "Returns the active room totals used for validation and responses."
  def totals(group_id) do
    rooms = rooms_with_funding(group_id)
    active_rooms = Enum.filter(rooms, &(&1.status == "active"))

    %{
      lodging_total_cents: Enum.sum(Enum.map(active_rooms, & &1.lodging_cents)),
      deposit_due_cents: Enum.sum(Enum.map(active_rooms, & &1.deposit_due_cents)),
      cash_paid_cents: Enum.sum(Enum.map(active_rooms, & &1.cash_paid_cents)),
      credit_paid_cents: Enum.sum(Enum.map(active_rooms, & &1.credit_paid_cents)),
      deposit_paid_cents:
        Enum.sum(Enum.map(active_rooms, &(&1.cash_paid_cents + &1.credit_paid_cents)))
    }
  end

  @doc "Returns current dispositions for a durable cash payment."
  def payment_dispositions(operation_id) do
    from(a in CashAllocation,
      where: a.payment_operation_id == ^operation_id,
      select: %{
        held_cents: coalesce(sum(a.held_cents), 0),
        refunded_cents: coalesce(sum(a.refunded_cents), 0),
        retained_cents: coalesce(sum(a.retained_cents), 0),
        converted_to_credit_cents: coalesce(sum(a.converted_to_credit_cents), 0),
        reduced_cents: coalesce(sum(a.reduced_cents), 0),
        charged_back_cents: coalesce(sum(a.charged_back_cents), 0)
      }
    )
    |> Repo.one()
  end

  def serialize_group(%Group{} = group) do
    rooms = rooms_with_funding(group.group_id)
    active_rooms = Enum.filter(rooms, &(&1.status == "active"))
    totals = totals_from_rooms(active_rooms)

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
      rooms: Enum.map(rooms, &serialize_room/1),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents
    }
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

  defp serialize_room(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_cents: room.lodging_cents,
      status: room.status,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: room.cash_paid_cents,
      credit_paid_cents: room.credit_paid_cents
    }
  end

  defp totals_from_rooms(rooms) do
    %{
      lodging_total_cents: Enum.sum(Enum.map(rooms, & &1.lodging_cents)),
      deposit_due_cents: Enum.sum(Enum.map(rooms, & &1.deposit_due_cents)),
      cash_paid_cents: Enum.sum(Enum.map(rooms, & &1.cash_paid_cents)),
      credit_paid_cents: Enum.sum(Enum.map(rooms, & &1.credit_paid_cents)),
      deposit_paid_cents: Enum.sum(Enum.map(rooms, &(&1.cash_paid_cents + &1.credit_paid_cents)))
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

  defp cash_sum(field) do
    Repo.one(from a in CashAllocation, select: coalesce(sum(field(a, ^field)), 0))
  end

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

  defp credit_shortfall do
    rows =
      from(l in CreditLot,
        join: a in CreditAllocation,
        on: a.credit_lot_id == l.id,
        join: g in Group,
        on: g.group_id == a.group_id,
        where: g.status == "active",
        group_by: [l.id, l.unrecovered_clawback_cents],
        select: {l.unrecovered_clawback_cents, coalesce(sum(a.amount_cents), 0)}
      )
      |> Repo.all()

    Enum.sum(Enum.map(rows, fn {unrecovered, applied} -> min(unrecovered || 0, applied) end))
  end
end
