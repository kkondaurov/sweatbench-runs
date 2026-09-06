defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.{CashAllocation, CreditLot, Group, GroupCreditAllocation, GroupRoom, Repo}
  alias GroupStay.CancellationPolicy

  @cash_not_currently_paid ["reduced", "charged_back"]

  def get(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:error, :group_not_found}

      group ->
        {:ok,
         group
         |> Repo.preload(rooms: from(room in GroupRoom, order_by: room.position))
         |> add_room_balances()}
    end
  end

  def get(_group_id), do: {:error, :group_not_found}

  def ledger_totals(as_of \\ Date.utc_today()) do
    cash_totals =
      Repo.one(
        from allocation in CashAllocation,
          join: group in Group,
          on: group.id == allocation.group_record_id,
          where: allocation.disposition == "held" and group.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    Repo.all(
      from group in Group,
        select: {
          group.refunded_cents,
          group.retained_cents,
          group.cash_converted_to_credit_cents,
          group.cash_reduced_cents,
          group.cash_charged_back_cents
        }
    )
    |> Enum.reduce(
      %{
        cash_held_cents: cash_totals,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        cash_reduced_cents: 0,
        cash_charged_back_cents: 0
      },
      fn {refunded, retained, converted, reduced, charged_back}, totals ->
        %{
          totals
          | cash_refunded_cents: totals.cash_refunded_cents + refunded,
            cash_retained_cents: totals.cash_retained_cents + retained,
            cash_converted_to_credit_cents: totals.cash_converted_to_credit_cents + converted,
            cash_reduced_cents: totals.cash_reduced_cents + reduced,
            cash_charged_back_cents: totals.cash_charged_back_cents + charged_back
        }
      end
    )
    |> Map.put(:credit_liability_cents, credit_liability(as_of))
    |> Map.put(:credit_shortfall_cents, credit_shortfall())
  end

  def guest_credit(guest_id, as_of \\ Date.utc_today()) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where: lot.guest_id == ^guest_id and lot.remaining_cents > 0,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Enum.filter(&(Date.compare(&1.expires_on, as_of) == :gt))

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  def serialize(%Group{} = group) do
    rooms = add_room_balances(group).rooms
    active_rooms = Enum.filter(rooms, &(&1.status == "active"))
    nights = Date.diff(group.departure_on, group.arrival_on)

    lodging_total_cents =
      Enum.reduce(active_rooms, 0, &(&1.nightly_rate_cents * nights + &2))

    deposit_due_cents = Enum.reduce(active_rooms, 0, &(&1.deposit_due_cents + &2))
    cash_paid_cents = Enum.reduce(active_rooms, 0, &(&1.cash_paid_cents + &2))
    credit_paid_cents = Enum.reduce(active_rooms, 0, &(&1.credit_paid_cents + &2))
    deposit_paid_cents = cash_paid_cents + credit_paid_cents

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until:
        group.policy_version
        |> CancellationPolicy.refundable_until(group.arrival_on)
        |> format_date(),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: deposit_paid_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      outstanding_deposit_cents: max(deposit_due_cents - deposit_paid_cents, 0)
    }
  end

  defp add_room_balances(%Group{} = group) do
    cash_by_room =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.group_record_id == ^group.id,
          where: allocation.disposition not in ^@cash_not_currently_paid,
          group_by: allocation.group_room_id,
          select: {allocation.group_room_id, coalesce(sum(allocation.amount_cents), 0)}
      )
      |> Map.new()

    credit_by_room =
      Repo.all(
        from allocation in GroupCreditAllocation,
          where: allocation.group_record_id == ^group.id,
          group_by: allocation.group_room_id,
          select: {allocation.group_room_id, coalesce(sum(allocation.amount_cents), 0)}
      )
      |> Map.new()

    rooms =
      Enum.map(group.rooms, fn room ->
        %{
          room
          | cash_paid_cents: Map.get(cash_by_room, room.id, 0),
            credit_paid_cents: Map.get(credit_by_room, room.id, 0)
        }
      end)

    %{group | rooms: rooms}
  end

  defp credit_liability(as_of) do
    available =
      Repo.all(
        from lot in CreditLot,
          where: lot.remaining_cents > 0,
          select: {lot.remaining_cents, lot.expires_on}
      )
      |> Enum.reduce(0, fn {remaining, expires_on}, total ->
        if Date.compare(expires_on, as_of) == :gt, do: total + remaining, else: total
      end)

    applied =
      Repo.one(
        from allocation in GroupCreditAllocation,
          join: group in Group,
          on: group.id == allocation.group_record_id,
          where: group.status == "active" and allocation.status == "held",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + applied
  end

  defp credit_shortfall do
    lots = Repo.all(CreditLot)

    Enum.reduce(lots, 0, fn lot, total ->
      applied =
        Repo.one(
          from allocation in GroupCreditAllocation,
            join: group in Group,
            on: group.id == allocation.group_record_id,
            where:
              allocation.credit_lot_id == ^lot.id and group.status == "active" and
                allocation.status == "held",
            select: coalesce(sum(allocation.amount_cents), 0)
        )

      total + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)
end
