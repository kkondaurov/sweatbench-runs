defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.CreditAllocation
  alias GroupStay.CreditLot
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.{Ledger, Repo}

  def get(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :not_found
      group -> {:ok, serialize(group)}
    end
  end

  def ledger_totals(as_of \\ Date.utc_today()) do
    cash_held =
      Repo.all(from group in Group, where: group.status == "active")
      |> Enum.reduce(0, fn group, total -> total + cash_paid(group) end)

    active_credit =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      ) || 0

    credit_liability = available_credit_total(as_of) + active_credit

    ledger = Repo.get(Ledger, 1)

    %{
      cash_held_cents: cash_held,
      cash_refunded_cents: (ledger && ledger.cash_refunded_cents) || 0,
      cash_retained_cents: (ledger && ledger.cash_retained_cents) || 0,
      cash_converted_to_credit_cents: (ledger && ledger.cash_converted_to_credit_cents) || 0,
      credit_liability_cents: credit_liability
    }
  end

  def guest_credit(guest_id, as_of \\ Date.utc_today()) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
              lot.expires_on > ^as_of,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id],
          select: %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, fn lot, total -> total + lot.remaining_cents end),
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
      policy_version: group.policy_version || policy_version(group),
      refundable_until: format_date(group.refundable_until || refundable_until(group)),
      status: group.status,
      revision: group.revision,
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: cash_paid(group),
      credit_paid_cents: credit_paid(group),
      outstanding_deposit_cents: outstanding
    }
  end

  defp available_credit_total(as_of) do
    Repo.one(
      from lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on > ^as_of,
        select: coalesce(sum(lot.remaining_cents), 0)
    ) || 0
  end

  defp cash_paid(group), do: group.cash_paid_cents || group.deposit_paid_cents
  defp credit_paid(group), do: group.credit_paid_cents || 0

  defp policy_version(%{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  defp policy_version(%{rate_plan: "flexible", booked_on: booked_on}) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{rate_plan: "advance_purchase"}), do: nil

  defp refundable_until(group) do
    Date.add(group.arrival_on, cancellation_window(policy_version(group)))
  end

  defp cancellation_window("flex-30"), do: -30
  defp cancellation_window(_policy_version), do: -14

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)
end
