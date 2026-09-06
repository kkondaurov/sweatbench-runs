defmodule GroupStay.Groups do
  @moduledoc """
  The read model for group reservations and finance totals.
  """

  import Ecto.Query
  alias GroupStay.Credits
  alias GroupStay.Repo
  alias GroupStay.Schemas.{CreditLot, Group, Room, RoomAllocation}

  @policy_cutoff_date ~D[2027-01-01]

  def fetch(group_id) do
    rooms_query = from(r in Room, order_by: r.position)

    case Repo.one(
           from(g in Group, where: g.group_id == ^group_id, preload: [rooms: ^rooms_query])
         ) do
      nil -> :error
      group -> {:ok, group}
    end
  end

  def outstanding_deposit_cents(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%Group{} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  def policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def policy_version("flexible", %Date{} = booked_on) do
    if Date.compare(booked_on, @policy_cutoff_date) == :lt, do: "flex-14", else: "flex-30"
  end

  def refundable_until(%Group{policy_version: "advance-nonrefundable"}), do: nil

  def refundable_until(%Group{policy_version: policy_version, arrival_on: arrival_on}) do
    case refund_window_days(policy_version) do
      nil -> nil
      days -> Date.add(arrival_on, -days)
    end
  end

  def refundable?(%Group{} = group, %Date{} = occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refund_window_days("flex-14"), do: 14
  defp refund_window_days("flex-30"), do: 30
  defp refund_window_days(_other), do: nil

  def ledger_totals(as_of \\ Date.utc_today()) do
    totals =
      Repo.one(
        from g in Group,
          select: %{
            cash_held_cents:
              fragment(
                "COALESCE(SUM(CASE WHEN ? = 'active' THEN ? ELSE 0 END), 0)",
                g.status,
                g.cash_paid_cents
              ),
            cash_refunded_cents: fragment("COALESCE(SUM(?), 0)", g.refunded_cents),
            cash_retained_cents: fragment("COALESCE(SUM(?), 0)", g.retained_cents),
            cash_converted_to_credit_cents:
              fragment("COALESCE(SUM(?), 0)", g.converted_to_credit_cents),
            cash_reduced_cents: fragment("COALESCE(SUM(?), 0)", g.cash_reduced_cents),
            cash_charged_back_cents: fragment("COALESCE(SUM(?), 0)", g.cash_charged_back_cents),
            credit_applied_cents:
              fragment(
                "COALESCE(SUM(CASE WHEN ? = 'active' THEN ? ELSE 0 END), 0)",
                g.status,
                g.credit_paid_cents
              )
          }
      )

    %{
      cash_held_cents: totals.cash_held_cents,
      cash_refunded_cents: totals.cash_refunded_cents,
      cash_retained_cents: totals.cash_retained_cents,
      cash_converted_to_credit_cents: totals.cash_converted_to_credit_cents,
      cash_reduced_cents: totals.cash_reduced_cents,
      cash_charged_back_cents: totals.cash_charged_back_cents,
      credit_liability_cents: Credits.available_cents(as_of) + totals.credit_applied_cents,
      credit_shortfall_cents: credit_shortfall_cents()
    }
  end

  # A lot's current shortfall is the lesser of its unrecovered clawback and
  # credit from that lot still applied to active groups. Room allocations
  # exist only for funding on active rooms, so the applied amount per lot is
  # the sum of its remaining credit allocations.
  defp credit_shortfall_cents do
    applied_by_lot =
      Repo.all(
        from a in RoomAllocation,
          where: a.kind == "credit",
          group_by: a.credit_lot_id,
          select: {a.credit_lot_id, fragment("COALESCE(SUM(?), 0)", a.amount_cents)}
      )
      |> Map.new()

    Repo.all(
      from l in CreditLot,
        where: l.unrecovered_clawback_cents > 0,
        select: %{lot_id: l.id, clawback_cents: l.unrecovered_clawback_cents}
    )
    |> Enum.map(&min(&1.clawback_cents, Map.get(applied_by_lot, &1.lot_id, 0)))
    |> Enum.sum()
  end
end
