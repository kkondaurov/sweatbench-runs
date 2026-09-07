defmodule GroupStay.Reservations do
  @moduledoc """
  Read access to reservations, hotel credit, and finance totals.

  Ledger totals are derived from reservation settlement fields. Keeping those values on the same
  row makes cancellation and its accounting effect one atomic database update.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{GroupReservation, HotelCreditAllocation, HotelCreditLot}

  @doc "Returns a group with its rooms in the partner-provided order."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(GroupReservation, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  @doc "Returns cash settlement totals and hotel-credit liability as of a calendar date."
  def ledger_totals(on \\ Date.utc_today()) do
    query =
      from group in GroupReservation,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  group.status,
                  group.cash_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
          cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0),
          cash_converted_to_credit_cents: coalesce(sum(group.cash_converted_to_credit_cents), 0),
          cash_reduced_cents: coalesce(sum(group.cash_reduced_cents), 0),
          cash_charged_back_cents: coalesce(sum(group.cash_charged_back_cents), 0)
        }

    Repo.one(query)
    |> Map.put(:credit_liability_cents, credit_liability(on))
    |> Map.put(:credit_shortfall_cents, credit_shortfall())
  end

  @doc "Returns a guest's unexpired, unredeemed credit lots in consumption order."
  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      from(lot in HotelCreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    %{guest_id: guest_id, available_cents: Enum.sum_by(lots, & &1.remaining_cents), lots: lots}
  end

  @doc false
  def outstanding_deposit(%GroupReservation{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  def outstanding_deposit(%GroupReservation{}), do: 0

  defp credit_liability(on) do
    available =
      Repo.one(
        from lot in HotelCreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    # Allocated credit has its expiry paused. Allocation rows are removed on either cancellation
    # settlement, so every remaining row funds an active group.
    allocated =
      Repo.one(
        from allocation in HotelCreditAllocation,
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + allocated
  end

  defp credit_shortfall do
    applied_by_lot =
      from(allocation in HotelCreditAllocation,
        group_by: allocation.lot_id,
        select: {allocation.lot_id, sum(allocation.amount_cents)}
      )
      |> Repo.all()
      |> Map.new()

    Repo.all(
      from lot in HotelCreditLot,
        where: lot.unrecovered_clawback_cents > 0,
        select: {lot.id, lot.unrecovered_clawback_cents}
    )
    |> Enum.sum_by(fn {lot_id, clawback} -> min(clawback, Map.get(applied_by_lot, lot_id, 0)) end)
  end
end
