defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.{CreditLot, Group, GroupCreditAllocation, GroupRoom, Repo}
  alias GroupStay.CancellationPolicy

  def get(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, rooms: from(room in GroupRoom, order_by: room.position))}
    end
  end

  def get(_group_id), do: {:error, :group_not_found}

  def ledger_totals(as_of \\ Date.utc_today()) do
    Repo.all(
      from group in Group,
        select: {
          group.status,
          group.cash_paid_cents,
          group.refunded_cents,
          group.retained_cents,
          group.cash_converted_to_credit_cents
        }
    )
    |> Enum.reduce(
      %{
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0
      },
      fn {status, cash_paid, refunded, retained, converted}, totals ->
        %{
          cash_held_cents:
            if(status == "active",
              do: totals.cash_held_cents + cash_paid,
              else: totals.cash_held_cents
            ),
          cash_refunded_cents: totals.cash_refunded_cents + refunded,
          cash_retained_cents: totals.cash_retained_cents + retained,
          cash_converted_to_credit_cents: totals.cash_converted_to_credit_cents + converted
        }
      end
    )
    |> Map.put(:credit_liability_cents, credit_liability(as_of))
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
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
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
          where: group.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + applied
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp outstanding_deposit(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding_deposit(%Group{}), do: 0
end
