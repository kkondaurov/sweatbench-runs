defmodule GroupStay.Groups do
  @moduledoc """
  Persistence and presentation helpers for group reservations.
  """

  import Ecto.Query

  alias GroupStay.CancellationPolicy

  alias GroupStay.Groups.{
    CashPayment,
    CreditApplication,
    CreditLot,
    Group,
    Room,
    RoomCreditAllocation
  }

  alias GroupStay.Repo

  def get(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, rooms: from(room in Room, order_by: room.position))
    end
  end

  def get(_group_id), do: nil

  def present(group) do
    policy_version = policy_version(group)
    totals = active_room_totals(group.rooms)

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
      policy_version: policy_version,
      refundable_until:
        format_date(CancellationPolicy.refundable_until(policy_version, group.arrival_on)),
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: max(totals.deposit_due_cents - totals.deposit_paid_cents, 0)
    }
  end

  def outstanding_deposit(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  def outstanding_deposit(%Group{}), do: 0

  def ledger(on \\ Date.utc_today()) do
    %{
      cash_held_cents: held_cash(),
      cash_refunded_cents: sum(:cancelled_refunded_cents),
      cash_retained_cents: sum(:cancelled_retained_cents),
      cash_converted_to_credit_cents: sum(:cancelled_cash_converted_to_credit_cents),
      cash_reduced_cents: payment_sum(:reduced_cents),
      cash_charged_back_cents: payment_sum(:charged_back_cents),
      credit_liability_cents: available_credit_liability(on) + applied_credit_liability(),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum_by(lots, & &1.remaining_cents),
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

  def available_lots(guest_id, on) do
    Repo.all(
      from(lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
    )
  end

  def policy_version(%Group{policy_version: policy_version}) when is_binary(policy_version),
    do: policy_version

  def policy_version(%Group{} = group),
    do: CancellationPolicy.version(group.rate_plan, group.booked_on)

  def cash_paid(%Group{cash_paid_cents: cash_paid_cents}) when is_integer(cash_paid_cents),
    do: cash_paid_cents

  def cash_paid(%Group{} = group), do: group.deposit_paid_cents - group.credit_paid_cents

  defp sum(field, filters \\ []) do
    query = from(group in Group, select: coalesce(sum(field(group, ^field)), 0))

    query =
      case Keyword.fetch(filters, :status) do
        {:ok, status} -> from(group in query, where: group.status == ^status)
        :error -> query
      end

    Repo.one(query)
  end

  defp available_credit_liability(on) do
    Repo.one(
      from(lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
        select: coalesce(sum(lot.remaining_cents), 0)
      )
    )
  end

  defp applied_credit_liability do
    Repo.one(
      from(room in Room,
        where: room.status == "active",
        select: coalesce(sum(room.credit_paid_cents), 0)
      )
    )
  end

  defp held_cash do
    Repo.one(
      from(room in Room,
        where: room.status == "active",
        select: coalesce(sum(room.cash_paid_cents), 0)
      )
    )
  end

  defp payment_sum(field) do
    Repo.one(from(payment in CashPayment, select: coalesce(sum(field(payment, ^field)), 0)))
  end

  defp credit_shortfall do
    Repo.all(
      from(lot in CreditLot,
        left_join: application in CreditApplication,
        on: application.credit_lot_id == lot.id,
        left_join: allocation in RoomCreditAllocation,
        on: allocation.credit_application_id == application.id,
        left_join: room in Room,
        on: room.id == allocation.room_id,
        group_by: [lot.id, lot.unrecovered_clawback_cents],
        select:
          {lot.unrecovered_clawback_cents,
           coalesce(
             sum(
               fragment(
                 "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                 room.status,
                 allocation.amount_cents
               )
             ),
             0
           )}
      )
    )
    |> Enum.sum_by(fn {unrecovered, applied} -> min(unrecovered, applied) end)
  end

  defp active_room_totals(rooms) do
    rooms
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.reduce(
      %{
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      },
      fn room, totals ->
        %{
          lodging_total_cents: totals.lodging_total_cents + room.lodging_total_cents,
          deposit_due_cents: totals.deposit_due_cents + room.deposit_due_cents,
          deposit_paid_cents:
            totals.deposit_paid_cents + room.cash_paid_cents + room.credit_paid_cents,
          cash_paid_cents: totals.cash_paid_cents + room.cash_paid_cents,
          credit_paid_cents: totals.credit_paid_cents + room.credit_paid_cents
        }
      end
    )
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)
end
