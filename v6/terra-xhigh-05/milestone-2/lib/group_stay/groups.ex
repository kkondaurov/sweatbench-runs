defmodule GroupStay.Groups do
  @moduledoc """
  Persistence and presentation helpers for group reservations.
  """

  import Ecto.Query

  alias GroupStay.CancellationPolicy
  alias GroupStay.Groups.{CreditApplication, CreditLot, Group, Room}
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
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: cash_paid(group),
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  def outstanding_deposit(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  def outstanding_deposit(%Group{}), do: 0

  def ledger(on \\ Date.utc_today()) do
    %{
      cash_held_cents: sum(:cash_paid_cents, status: "active"),
      cash_refunded_cents: sum(:cancelled_refunded_cents),
      cash_retained_cents: sum(:cancelled_retained_cents),
      cash_converted_to_credit_cents: sum(:cancelled_cash_converted_to_credit_cents),
      credit_liability_cents: available_credit_liability(on) + applied_credit_liability()
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
      from(application in CreditApplication,
        join: group in Group,
        on: group.id == application.reservation_id,
        where: group.status == "active",
        select: coalesce(sum(application.amount_cents), 0)
      )
    )
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)
end
