defmodule GroupStay.Groups do
  @moduledoc """
  Read-side access to group reservations, guest credit, and the finance totals
  derived from them.
  """

  import Ecto.Query

  alias GroupStay.Groups.{CreditApplication, CreditLot, Group}
  alias GroupStay.Repo

  @doc """
  Fetches a group by its partner identifier, with rooms included.

  Returns `nil` when no group matches.
  """
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  @doc """
  Renders a group for the API, rooms in their original order, with derived
  totals.
  """
  def group_view(%Group{} = group) do
    rooms = Enum.sort_by(group.rooms, & &1.position)
    nights = nights(group)

    lodging_total_cents =
      Enum.reduce(rooms, 0, fn room, total ->
        total + room.nightly_rate_cents * nights
      end)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: Group.refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents
    }
  end

  @doc """
  Finance totals across all groups.

  Cash currently applied to active groups is held; cancellation settles each
  group's cash as refunded, retained, or converted to hotel credit. Unpaid
  deposit requirements are not cash and never appear here.

  `credit_liability_cents` reports the credit liability as of the given date:
  unexpired lot balances plus credit currently applied to active groups.
  """
  def ledger_totals(%Date{} = as_of) do
    %{
      cash_held_cents: sum_field(from(g in Group, where: g.status == "active"), :cash_paid_cents),
      cash_refunded_cents:
        sum_field(from(g in Group, where: g.status == "cancelled"), :refunded_cents),
      cash_retained_cents:
        sum_field(from(g in Group, where: g.status == "cancelled"), :retained_cents),
      cash_converted_to_credit_cents:
        sum_field(from(g in Group, where: g.status == "cancelled"), :converted_to_credit_cents),
      credit_liability_cents: credit_liability(as_of)
    }
  end

  @doc """
  A guest's available hotel credit as of the given date.

  Expired and exhausted lots are omitted, ordered by expiry and then by the
  operation that issued them.
  """
  def guest_credit(guest_id, %Date{} = as_of) when is_binary(guest_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^as_of,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, fn lot, total -> total + lot.remaining_cents end),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  defp credit_liability(as_of) do
    unexpired_lot_cents =
      sum_field(from(l in CreditLot, where: l.expires_on > ^as_of), :remaining_cents)

    applied_credit_cents =
      sum_field(from(a in CreditApplication, where: a.state == "applied"), :amount_cents)

    unexpired_lot_cents + applied_credit_cents
  end

  defp sum_field(query, field) do
    Repo.aggregate(query, :sum, field) || 0
  end

  defp nights(%Group{} = group) do
    Date.diff(group.departure_on, group.arrival_on)
  end
end
